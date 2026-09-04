// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception
import SwiftTerm
import UIKit

/// One terminal tab: an SSH connection, its shell, and the view showing it.
///
/// The `TerminalView` is owned here rather than created by the SwiftUI view.
/// That is what lets a tab keep its scrollback and cursor position when the user
/// switches away and back — the same reason the Android `SessionManager` holds
/// the `TerminalEmulator` instead of the screen.
@MainActor
@Perceptible
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

    /// Whether the soft keyboard offers suggestions and autocorrection.
    ///
    /// Android's "word mode", the Spellcheck key on its extra row, which swaps
    /// the terminal's input type between raw keys and
    /// `TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_AUTO_CORRECT`. Off is the right default
    /// for a terminal and is what SwiftTerm already does; on is for the moment
    /// you are composing a long command and want the keyboard's help with the
    /// prose-like parts of it.
    ///
    /// Only autocorrection and spell checking move. Capitalisation stays off —
    /// Android sets no capitalisation flag either, and a shell is case-sensitive
    /// — and so do smart quotes and dashes, which would turn `"` into `"` and
    /// `--flag` into `–flag` and break the command outright.
    var wordMode = false {
        didSet {
            guard wordMode != oldValue else { return }
            terminalView.autocorrectionType = wordMode ? .yes : .no
            terminalView.spellCheckingType = wordMode ? .yes : .no
            // The traits are read when the keyboard attaches, so it has to be
            // rebuilt for the change to show — the counterpart of Android having
            // to call `restartInput()` for the same reason.
            if terminalView.isFirstResponder {
                terminalView.reloadInputViews()
            }
        }
    }

    /// Suggestions for what is being typed, or empty when there is nothing to
    /// offer. Driven by the terminal's own contents, so completion and history
    /// recall move it too, not only keystrokes.
    private(set) var suggestions: [String] = []

    @PerceptionIgnored private var history = CommandHistory.empty
    @PerceptionIgnored private var suggestionTask: Task<Void, Never>?

    /// State of this host's port forwarding rules, empty when it has none.
    ///
    /// Observed rather than silent because a rule that could not bind is the
    /// one thing the user has to be told: the terminal works perfectly while
    /// the forwarded port simply is not there.
    private(set) var forwardingStatus: [PortForwarder.Status] = []

    /// Set when the user closed the session, so returning to the foreground does
    /// not resurrect something they deliberately ended.
    @PerceptionIgnored private var closedByUser = false

    /// Set when the remote shell exited by itself — `exit`, or a killed session.
    /// Reconnecting then would undo what the user just asked for.
    @PerceptionIgnored private var endedByRemote = false

    /// Called when the remote shell exited by itself, so the tab can go.
    ///
    /// A session cannot remove itself: the list belongs to ``SessionManager``,
    /// which sets this when it opens one.
    @PerceptionIgnored var onShellExited: ((TerminalSession) -> Void)?

    /// The password the user typed for the connection currently being made.
    ///
    /// Held only for as long as the attempt lasts, because that attempt can take
    /// more than one round trip: a first connection asks for the password, then
    /// for the host key, and the second answer must not lose the first. Dropped
    /// the moment the shell is up, and when the session is closed — it exists to
    /// survive a prompt, not to be a stored credential. Saving a password is a
    /// separate, deliberate act in the host editor.
    @PerceptionIgnored private var passwordForThisAttempt: String?

    /// The credential that just worked, kept only until the history has been
    /// fetched and then dropped.
    ///
    /// History opens a second connection of its own, and by the time it runs the
    /// typed password is already gone — `passwordForThisAttempt` is cleared the
    /// instant the shell is up. So `resolveAuth(typedPassword: nil)` had nothing
    /// left to return for a host whose password is typed rather than saved, and
    /// the suggestion bar never appeared. Reported 05/09/2026 as working on
    /// Android for the same host, which reuses `lastConnectParams` directly.
    ///
    /// Deliberately *not* the same thing as keeping the password for the session.
    /// `reconnectAutomatically` still refuses to reuse a typed password, and that
    /// stays refused: this is held for the seconds between connecting and reading
    /// one file, and `loadHistory` clears it in a `defer` whichever way it exits.
    @PerceptionIgnored private var authForHistory: SSHAuth?

    /// The last size the view actually reported, as opposed to the one the
    /// terminal object carries before it has ever been laid out.
    @PerceptionIgnored private var measuredSize: (columns: Int, rows: Int)?

    @PerceptionIgnored private var forwarder: PortForwarder?
    @PerceptionIgnored private var forwardingTask: Task<Void, Never>?

    @PerceptionIgnored private let hosts: HostRepository
    @PerceptionIgnored private let keys: SSHKeyRepository
    @PerceptionIgnored private var sshSession: SSHSession?
    @PerceptionIgnored private var channel: SSHShellChannel?
    @PerceptionIgnored private var readerTask: Task<Void, Never>?
    @PerceptionIgnored private var bridge: TerminalDelegateBridge?

    init(host: Host, hosts: HostRepository, keys: SSHKeyRepository) {
        self.host = host
        self.hosts = hosts
        self.keys = keys
        self.title = host.label
        // Plain SwiftTerm view. Narrowing the paste item to "only when the
        // clipboard holds text" — which the Android build does, and which
        // avoids a menu entry that does nothing — would mean overriding
        // canPerformAction, and SwiftTerm declares it `public` rather than
        // `open`, so a subclass outside that module cannot. Paste itself is
        // already there; only the refinement is out of reach without a one-line
        // change upstream.
        self.terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))

        let bridge = TerminalDelegateBridge()
        bridge.session = self
        self.bridge = bridge
        terminalView.terminalDelegate = bridge

        // Without this SwiftTerm never calls `rangeChanged`, and it defaults to
        // false. That single line is why the suggestion bar stayed empty: the
        // history loaded (382 commands, confirmed on the device), the prompt
        // parsed, the matching worked — and nothing ever asked for it, because
        // the delegate callback that drives it was switched off at the source.
        //
        // Found on 05/09/2026 by instrumenting the chain and finding not one of
        // `change`, `scheduled` or `debounceFired` in a full session's log. An
        // absence, rather than a wrong value, which is why reading the code had
        // not turned it up: everything on our side was correct.
        terminalView.notifyUpdateChanges = true
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
            // Handed to the history fetch, which runs next and cannot ask for a
            // credential of its own; see `authForHistory`.
            authForHistory = params.auth
            passwordForThisAttempt = nil

            // Open a session and the keyboard is there, as on Android, where the
            // terminal takes focus on attach and `reattachIme()` raises the IME.
            // Arriving at a shell prompt and having to tap before typing is a
            // step nobody wants.
            //
            // Here rather than in the view, and so once per connection: the view
            // is rebuilt on every SwiftUI update, and asking there would drag the
            // keyboard back up each time — including right after the user put it
            // away with the bar's hide key. It waits for `connected` so it cannot
            // steal focus from the password prompt, which needs it first.
            terminalView.becomeFirstResponder()

            try? await persistAfterConnect(hostKey: session.hostKey)
            await planner.persistJumpHostKeys(session.newJumpHostKeys, for: host)
            startForwarding(params)
            startReading(from: channel)
        } catch SSHError.unknownHostKey(let info) {
            phase = .needsHostKeyApproval(info, isChange: false)
        } catch SSHError.hostKeyMismatch(let info) {
            phase = .needsHostKeyApproval(info, isChange: true)
        } catch SSHError.authenticationFailed(let detail) {
            // Forget it: the server has just said this password is wrong, and
            // keeping it made Retry try the same wrong password again without
            // asking — silently, so it looked like the button did nothing.
            //
            // Only on an authentication failure. A connection that broke for any
            // other reason has said nothing about the credential, and making the
            // user retype it after a dropped Wi-Fi packet would be its own
            // annoyance.
            passwordForThisAttempt = nil
            phase = .failed(detail)
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
        // Falls back to the password typed earlier in this same attempt.
        //
        // Connecting to a new host asks two questions in a row, and the second
        // used to erase the answer to the first: type the password, get the host
        // key prompt, trust the key — and `connect(acceptHostKey:)` carries no
        // password, so the whole thing came back to the password prompt looking
        // exactly like a rejected credential. Reported as "it asks for the
        // password again as if I had got it wrong".
        if let typedPassword, !typedPassword.isEmpty {
            passwordForThisAttempt = typedPassword
        }

        if let carried = passwordForThisAttempt, !carried.isEmpty {
            return .password(carried)
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

        // A clean shell exit and a dropped link both land here, and what tells
        // them apart is *whether* an exit status arrived — not what it was.
        //
        // ⚠️ A shell that is *killed* counts as a clean exit here, and its tab
        // closes. SSH does distinguish the two — `exit-signal` rather than
        // `exit-status` — and Android keeps the panel for a killed shell, because
        // JSch reports "no status received" as -1 while libssh2 reports 0 for
        // that and for a genuine exit 0 alike. Reading the signal was tried on
        // 14/08/2026 and removed the same day: it worked in a test that killed
        // the shell from inside, and made no difference to killing it from
        // another session, which is the case that prompted it. Deliberate, and
        // the user's call — not an oversight to fix on sight.
        //
        // This used to report `exit status 1` as the reason for disconnecting,
        // which turned an ordinary goodbye into something that read like a
        // fault. `exit` with no argument carries the status of the last command,
        // so any failed command before leaving produces a non-zero value; it
        // describes the shell's last act, not the connection. Android draws the
        // line the same way: `if (session.exitStatus != -1) cleanExit = true`,
        // and it never shows the number.
        //
        // A dropped link, by contrast, has no status at all, and that is the
        // case that deserves words — it used to be the silent one.
        let endedCleanly = channel?.exitStatus != nil

        // A shell that exited on its own is finished, and reconnecting it would
        // undo what the user just did by typing `exit`.
        endedByRemote = endedCleanly
        phase = .disconnected(
            reason: endedCleanly ? nil : String(localized: .terminalConnectionLost)
        )

        // `exit` closes the tab; anything else leaves the panel up.
        //
        // Android splits the two the same way — `if (cleanExit) navBack else
        // show the disconnected state` — and the asymmetry is the point: someone
        // who typed `exit` has already decided they are done, so a panel telling
        // them the session ended is a second thing to dismiss. A connection that
        // died on its own is news, and the panel is where the last of the output
        // and a Reconnect button stay reachable.
        if endedCleanly { onShellExited?(self) }
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
        passwordForThisAttempt = nil
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
        // ⚠️ Every exit below is silent, and that cost a day: "the suggestion
        // bar never appears" carried no information about which of five places
        // it stopped at. Instrumenting them temporarily is what found the real
        // cause, which was none of them. If this needs debugging again, name the
        // exits again before guessing at them.
        guard preferences.historySuggestions else { return }

        // The credential that just worked, not a fresh resolution: by now the
        // typed password has been cleared, and asking again would come back
        // empty for any host whose password is not saved.
        defer { authForHistory = nil }
        // Written out rather than with `??`: that operator takes an autoclosure,
        // which cannot be async, so the fallback has to be a statement.
        let resolved: SSHAuth?
        if let working = authForHistory {
            resolved = working
        } else {
            resolved = try? await resolveAuth(typedPassword: nil)
        }
        guard let auth = resolved else {
            return
        }

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

        guard let sftp = try? await SFTPSession.connect(params) else {
            return
        }
        defer { sftp.disconnect() }

        var loaded: [CommandHistory] = []
        for name in CommandHistory.candidatePaths {
            let path = sftp.homePath == "/" ? "/\(name)" : "\(sftp.homePath)/\(name)"
            if let data = try? await sftp.readSmallFile(at: path) {
                loaded.append(CommandHistory.parse(data))
            }
        }

        history = CommandHistory.merging(loaded)

        // Recompute now. Suggestions are otherwise driven only by `rangeChanged`,
        // and the history usually finishes loading a second or two after the
        // prompt has settled — by which point the terminal has nothing left to
        // redraw, so nothing asks again until the next keystroke. Sitting at a
        // prompt with something already typed would show an empty bar for no
        // reason the user could see.
        refreshSuggestions()

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
