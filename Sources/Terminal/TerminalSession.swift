// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// Suggestions for what is being typed, or empty when there is nothing to
    /// offer. Driven by the terminal's own contents, so completion and history
    /// recall move it too, not only keystrokes.
    private(set) var suggestions: [String] = []

    @ObservationIgnored private var history = CommandHistory.empty
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?

    /// State of this host's port forwarding rules, empty when it has none.
    ///
    /// Observed rather than silent because a rule that could not bind is the
    /// one thing the user has to be told: the terminal works perfectly while
    /// the forwarded port simply is not there.
    private(set) var forwardingStatus: [PortForwarder.Status] = []

    /// Set when the user closed the session, so returning to the foreground does
    /// not resurrect something they deliberately ended.
    @ObservationIgnored private var closedByUser = false

    /// Set when the remote shell exited by itself — `exit`, or a killed session.
    /// Reconnecting then would undo what the user just asked for.
    @ObservationIgnored private var endedByRemote = false

    /// The last size the view actually reported, as opposed to the one the
    /// terminal object carries before it has ever been laid out.
    @ObservationIgnored private var measuredSize: (columns: Int, rows: Int)?

    @ObservationIgnored private var forwarder: PortForwarder?
    @ObservationIgnored private var forwardingTask: Task<Void, Never>?

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
        closedByUser = false
        endedByRemote = false
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

        // Open the PTY at the size the view really has.
        //
        // `connect()` runs from a `.task`, which can start before SwiftUI has
        // laid the terminal out; the terminal object then still reports the
        // 80x24 it was created with. A server that pads its MOTD to the terminal
        // width sends it for the wrong width, and the greeting arrives truncated
        // — which is the bug the Android build fixed the same way, by waiting
        // for the first real measurement.
        //
        // Bounded wait: a view that never reports a size must not stop the
        // connection from happening at all.
        let geometry = await measuredGeometry()
        let planner = ConnectionPlanner(hosts: hosts, keys: keys)
        let params = await planner.params(
            for: host,
            auth: auth,
            hostKeyPolicy: hostKeyPolicy(acceptHostKey: acceptHostKey)
        )

        do {
            let session = try await SSHSession.connect(params)
            let channel = try await session.openShell(
                columns: geometry.columns,
                rows: geometry.rows
            )

            self.sshSession = session
            self.channel = channel
            phase = .connected

            try? await persistAfterConnect(hostKey: session.hostKey)
            await planner.persistJumpHostKeys(session.newJumpHostKeys, for: host)
            startForwarding(params)
            startReading(from: channel)
        } catch SSHError.unknownHostKey(let info) {
            phase = .needsHostKeyApproval(info, isChange: false)
        } catch SSHError.hostKeyMismatch(let info) {
            phase = .needsHostKeyApproval(info, isChange: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Waits briefly for the view to report its size, then falls back to
    /// whatever the terminal object says.
    private func measuredGeometry() async -> (columns: Int, rows: Int) {
        // Eight short waits totalling 400ms rather than one long one, so a view
        // that lays out quickly — the usual case — is not made to wait for the
        // whole budget. Same ceiling the Android fallback uses.
        for _ in 0..<8 where measuredSize == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let measuredSize { return measuredSize }

        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    /// Brings up this host's `-L` rules, if it has any.
    ///
    /// Deliberately not awaited: forwarding opens a second SSH connection, and
    /// making the terminal wait for it would delay a working shell for a feature
    /// the user may not be about to use. Failures land in ``forwardingStatus``
    /// rather than stopping the session.
    private func startForwarding(_ params: SSHConnectionParams) {
        guard !params.portForwardings.isEmpty else { return }

        forwardingTask?.cancel()
        forwardingTask = Task { [weak self] in
            guard let forwarder = try? await PortForwarder.start(
                params.portForwardings,
                params: params
            ) else {
                self?.forwardingStatus = params.portForwardings.map {
                    PortForwarder.Status(
                        rule: $0,
                        isListening: false,
                        failure: "Could not open a connection for port forwarding."
                    )
                }
                return
            }

            guard let self, !Task.isCancelled else {
                forwarder.stop()
                return
            }
            self.forwarder = forwarder

            // The listeners reach `.ready` asynchronously, so the first status
            // read would otherwise always say "not listening yet".
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.forwardingStatus = forwarder.status
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
        // A shell that exited on its own is finished, and reconnecting it would
        // undo what the user just did by typing `exit`.
        endedByRemote = status != nil
        phase = .disconnected(reason: reason)
    }

    // MARK: - Returning to the foreground

    /// Brings the session back after iOS has suspended the app.
    ///
    /// An app off screen is suspended within about thirty seconds and its
    /// connections die. Android keeps them with a foreground service, which iOS
    /// has no equivalent of, so this is the mitigation named in the plan.
    ///
    /// **A reconnection is a new shell, not the old one.** Whatever was running
    /// is gone, along with the working directory and the environment. That is
    /// why it is announced in the scrollback rather than done quietly: the old
    /// output is still on screen, and without a marker the user would be typing
    /// into what looks like their session.
    func handleReturnToForeground() async {
        switch phase {
        case .connected:
            guard let sshSession, await sshSession.isAlive() == false else { return }
            endedByRemote = false
            phase = .disconnected(reason: nil)
            await reconnectAutomatically()

        case .disconnected:
            await reconnectAutomatically()

        // Nothing to do while connecting, and the two `needs…` cases are
        // questions already in front of the user.
        case .connecting, .needsPassword, .needsHostKeyApproval, .failed:
            return
        }
    }

    /// Reconnects when it can be done without asking anything.
    ///
    /// It deliberately does not reuse a password the user typed by hand. Keeping
    /// one in memory for the life of the app to make this seamless is a trade
    /// worth making explicitly rather than by default, so a host without a saved
    /// credential asks again — which the password prompt already handles.
    private func reconnectAutomatically() async {
        guard !closedByUser, !endedByRemote else { return }

        guard let auth = try? await resolveAuth(typedPassword: nil), auth != nil else {
            phase = .needsPassword
            return
        }

        let before = phase
        await connect()

        if case .connected = phase, case .disconnected = before {
            announceReconnection()
        }
    }

    /// Writes a rule into the local scrollback. Nothing is sent to the server —
    /// this is the app talking to the user, in the middle of the server's output.
    private func announceReconnection() {
        let label = String(localized: .iosTerminalReconnected)
        let banner = "\r\n\u{1B}[2m── \(label) ──\u{1B}[0m\r\n"
        terminalView.feed(text: banner)
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
        closedByUser = true
        readerTask?.cancel()
        readerTask = nil
        channel?.close()
        channel = nil
        forwarder?.stop()
        forwarder = nil
        forwardingStatus = []
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
        measuredSize = (columns, rows)
        resize(columns: columns, rows: rows)
    }

    fileprivate func terminalDidSetTitle(_ newTitle: String) {
        title = newTitle.isEmpty ? host.label : newTitle
    }

    /// The terminal redrew. Recompute suggestions, debounced: output arrives in
    /// bursts and rescanning on every chunk would be wasted work.
    fileprivate func terminalDidChange() {
        guard !history.commands.isEmpty else { return }

        suggestionTask?.cancel()
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refreshSuggestions() }
        }
    }

    private func refreshSuggestions() {
        let terminal = terminalView.getTerminal()
        let cursor = terminal.getCursorLocation()

        guard let line = terminal.getLine(row: cursor.y) else {
            suggestions = []
            return
        }

        // Only up to the cursor: anything after it is left over from a longer
        // line the user is editing in the middle of.
        let visible = line.translateToString(trimRight: true, startCol: 0, endCol: max(0, cursor.x))

        guard let typed = PromptParser.typedPortion(of: visible) else {
            suggestions = []
            return
        }
        suggestions = history.suggestions(for: typed)
    }

    /// Accepts a suggestion by replacing what is on the line with it.
    ///
    /// Ctrl+U clears the line first, which every common shell understands, so
    /// this does not have to count backspaces or know where the cursor is.
    func apply(suggestion: String) {
        send(Data([0x15]))
        send(text: suggestion)
        suggestions = []
    }

    // MARK: - History

    /// Loads the shell history from the server so the bar has something to
    /// offer. Best effort and silent: a missing history file is normal, and it
    /// is not worth interrupting a working terminal over.
    func loadHistory(preferences: AppPreferences) async {
        guard preferences.historySuggestions else { return }

        guard let auth = try? await resolveAuth(typedPassword: nil) else { return }

        // Same path as everything else, so a host behind a bastion gets its
        // history too. `acceptOnce` is safe here and only here: the terminal
        // session has already connected and had its key checked, so this is a
        // second connection to a host just verified, not a first sight of it.
        var params = await ConnectionPlanner(hosts: hosts, keys: keys).params(
            for: host,
            auth: auth,
            hostKeyPolicy: .acceptOnce
        )
        // History is a background convenience; it must not open listeners.
        params.portForwardings = []

        guard let sftp = try? await SFTPSession.connect(params) else { return }
        defer { sftp.disconnect() }

        var loaded: [CommandHistory] = []
        for name in CommandHistory.candidatePaths {
            let path = sftp.homePath == "/" ? "/\(name)" : "\(sftp.homePath)/\(name)"
            if let data = try? await sftp.readSmallFile(at: path) {
                loaded.append(CommandHistory.parse(data))
            }
        }

        history = CommandHistory.merging(loaded)
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

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        MainActor.assumeIsolated { session?.terminalDidChange() }
    }
}
