// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import SwiftTerm
import UIKit

/// One terminal tab: an SSH connection, its shell, and the view showing it.
///
/// The `TerminalView` is owned here rather than created by the SwiftUI view.
/// That is what lets a tab keep its scrollback and cursor position when the user
/// switches away and back — the same reason the Android `SessionManager` holds
/// the `TerminalEmulator` instead of the screen.
@MainActor
@Observable
final class TerminalSession: Identifiable {

    /// Where the connection currently is. The two `needs…` cases are questions
    /// for the user, and the screen answers them by calling ``connect(password:acceptHostKey:)``
    /// again.
    enum Phase: Equatable {
        case connecting
        case connected
        case needsPassword
        case needsHostKeyApproval(HostKeyInfo, isChange: Bool)
        case failed(String)
        case disconnected(reason: String?)
    }

    let id = UUID()
    let host: Host

    private(set) var phase: Phase = .connecting

    /// Window title as set by the remote through OSC, falling back to the host
    /// label. This is what the tab shows.
    private(set) var title: String

    let terminalView: TerminalView

    /// Sticky modifiers driven by the extra key row. They apply to the next
    /// character typed on the soft keyboard and then clear themselves, which is
    /// how the Android row behaves.
    var ctrlActive = false
    var altActive = false

    @ObservationIgnored private let hosts: HostRepository
    @ObservationIgnored private let keys: SSHKeyRepository
    @ObservationIgnored private var sshSession: SSHSession?
    @ObservationIgnored private var channel: SSHShellChannel?
    @ObservationIgnored private var readerTask: Task<Void, Never>?
    @ObservationIgnored private var bridge: TerminalDelegateBridge?

    init(host: Host, hosts: HostRepository, keys: SSHKeyRepository) {
        self.host = host
        self.hosts = hosts
        self.keys = keys
        self.title = host.label
        self.terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))

        let bridge = TerminalDelegateBridge()
        bridge.session = self
        self.bridge = bridge
        terminalView.terminalDelegate = bridge
    }

    deinit {
        readerTask?.cancel()
    }

    // MARK: - Connecting

    /// Connects, or reconnects after the user has supplied what was missing.
    ///
    /// - Parameters:
    ///   - password: typed by the user when the host has no stored credential.
    ///   - acceptHostKey: set once the user has seen the fingerprint and agreed.
    func connect(password: String? = nil, acceptHostKey: Bool = false) async {
        phase = .connecting

        let auth: SSHAuth
        do {
            guard let resolved = try await resolveAuth(typedPassword: password) else {
                phase = .needsPassword
                return
            }
            auth = resolved
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let geometry = terminalView.getTerminal()
        var params = SSHConnectionParams(
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            auth: auth,
            allowLegacyCiphers: host.allowLegacyCiphers
        )
        params.hostKeyPolicy = hostKeyPolicy(acceptHostKey: acceptHostKey)
        params.agentForwarding = host.agentForwarding

        do {
            let session = try await SSHSession.connect(params)
            let channel = try await session.openShell(
                columns: geometry.cols,
                rows: geometry.rows
            )

            self.sshSession = session
            self.channel = channel
            phase = .connected

            try? await persistAfterConnect(hostKey: session.hostKey)
            startReading(from: channel)
        } catch SSHError.unknownHostKey(let info) {
            phase = .needsHostKeyApproval(info, isChange: false)
        } catch SSHError.hostKeyMismatch(let info) {
            phase = .needsHostKeyApproval(info, isChange: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Picks the credential to use: an explicitly typed password wins, then the
    /// host's key, then its stored password. Returns `nil` when nothing is
    /// available and the user has to be asked.
    private func resolveAuth(typedPassword: String?) async throws -> SSHAuth? {
        if let typedPassword, !typedPassword.isEmpty {
            return .password(typedPassword)
        }

        if let keyId = host.keyId {
            guard let key = try await keys.fetch(id: keyId),
                  let pem = KeychainCrypto.privateKeyPEM(for: key)
            else {
                throw SSHError.invalidPrivateKey
            }
            return .publicKey(privateKeyPEM: pem)
        }

        return KeychainCrypto.password(for: host).map { SSHAuth.password($0) }
    }

    private func hostKeyPolicy(acceptHostKey: Bool) -> HostKeyPolicy {
        if acceptHostKey { return .acceptOnce }
        guard let stored = host.knownHostsEntry, !stored.isEmpty else { return .promptIfUnknown }
        return .requireMatch(stored)
    }

    /// Records the connection: pins the host key the first time, and stamps the
    /// last-connected time as the Android app does.
    private func persistAfterConnect(hostKey: HostKeyInfo) async throws {
        guard let id = host.id else { return }

        if host.knownHostsEntry?.isEmpty ?? true {
            try await hosts.updateKnownHostsEntry(id: id, to: hostKey.knownHostsLine)
        }
        try await hosts.updateLastConnected(id: id)
    }

    // MARK: - Streaming

    private func startReading(from channel: SSHShellChannel) {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            for await chunk in channel.output {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.terminalView.feed(byteArray: ArraySlice(chunk)) }
            }
            await MainActor.run { self?.handleStreamEnded() }
        }
    }

    private func handleStreamEnded() {
        guard case .connected = phase else { return }

        // A clean shell exit and a dropped link both land here; the exit status
        // is what tells them apart.
        let status = channel?.exitStatus
        let reason = (status == nil || status == 0) ? nil : "exit status \(status!)"
        phase = .disconnected(reason: reason)
    }

    // MARK: - Input

    func send(_ data: Data) {
        channel?.send(data)
    }

    func send(text: String) {
        send(Data(text.utf8))
    }

    /// Sends a ready-made sequence from the extra key row.
    ///
    /// Only Alt is applied here. Control is deliberately not: these are already
    /// escape sequences, and masking `ESC [` with `& 0x1F` would corrupt them
    /// rather than produce a control key.
    func sendExtraKey(_ data: Data) {
        if altActive {
            send(Data([0x1B]) + data)
            altActive = false
        } else {
            send(data)
        }
    }

    /// Maps a byte to its control-key equivalent, the standard `@`–`_` and
    /// `a`–`z` masking. Anything else is passed through untouched.
    static func applyControl(to data: Data) -> Data {
        Data(data.map { byte in
            switch byte {
            case 0x61...0x7A, 0x40...0x5F: byte & 0x1F
            default: byte
            }
        })
    }

    /// The escape sequence for a cursor key, honouring DECCKM: applications like
    /// vim and less put the terminal into application-cursor mode and expect
    /// `ESC O A` rather than `ESC [ A`.
    func cursorKey(_ code: Character) -> Data {
        let terminal = terminalView.getTerminal()
        let prefix = terminal.applicationCursor ? "\u{1B}O" : "\u{1B}["
        return Data((prefix + String(code)).utf8)
    }

    func resize(columns: Int, rows: Int) {
        channel?.resize(columns: columns, rows: rows)
    }

    // MARK: - Teardown

    func disconnect() {
        readerTask?.cancel()
        readerTask = nil
        channel?.close()
        channel = nil
        sshSession?.disconnect()
        sshSession = nil

        if case .connected = phase {
            phase = .disconnected(reason: nil)
        }
    }

    // MARK: - Delegate callbacks

    fileprivate func terminalDidSend(_ data: ArraySlice<UInt8>) {
        var bytes = Data(data)

        if ctrlActive {
            bytes = Self.applyControl(to: bytes)
            ctrlActive = false
        }
        if altActive {
            bytes = Data([0x1B]) + bytes
            altActive = false
        }

        send(bytes)
    }

    fileprivate func terminalDidResize(columns: Int, rows: Int) {
        resize(columns: columns, rows: rows)
    }

    fileprivate func terminalDidSetTitle(_ newTitle: String) {
        title = newTitle.isEmpty ? host.label : newTitle
    }
}

/// Adapts SwiftTerm's delegate to ``TerminalSession``.
///
/// The protocol is not main-actor annotated, but every call originates from
/// UIKit on the main thread, so `assumeIsolated` states that fact rather than
/// paying for a hop that would reorder terminal output.
private final class TerminalDelegateBridge: TerminalViewDelegate {

    weak var session: TerminalSession?

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { session?.terminalDidSend(data) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { session?.terminalDidResize(columns: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { session?.terminalDidSetTitle(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return }
        // Only hand the system schemes a remote cannot use to reach into the
        // app or the local network.
        guard scheme == "http" || scheme == "https" else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    func bell(source: TerminalView) {
        MainActor.assumeIsolated {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { UIPasteboard.general.string = text }
    }

    func clipboardRead(source: TerminalView) -> Data? {
        MainActor.assumeIsolated { UIPasteboard.general.string.map { Data($0.utf8) } }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
