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
        /// The server is asking for a password. Carries the banner it sent, so
        /// what it had to say is in front of the person before they type.
        case needsPassword(banner: String?)
        case needsHostKeyApproval(HostKeyInfo, isChange: Bool)
        /// Mosh was asked for and could not be had.
        ///
        /// There is no silent fall back to SSH: the switch is per host and
        /// explicit, so somebody who asked for mosh and did not get it is owed
        /// the reason and the choice. Carrying on costs nothing — the SSH
        /// session is already open, and it is the one that started the server.
        case moshUnavailable(MoshBootstrap.Unavailable)
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

    /// Double tap, inverted scrolling, scrollback and pinch, which all act on
    /// the view. Optional only because it needs `self` to exist first.
    @PerceptionIgnored private var touch: TerminalTouchHandling?

    /// The size a pinch left this tab at. It takes over from the default in
    /// Settings for as long as the tab lives, which is Android's `userScaled`.
    @PerceptionIgnored private(set) var zoomedFontSize: CGFloat?

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

    /// The `known_hosts` line the user looked at and accepted, until a shell
    /// comes up and writes it down for good.
    ///
    /// A first connection to a host asks two questions in a row, and here each
    /// answer costs a connection: the key is accepted, the next attempt gets as
    /// far as the password and stops to ask, and the attempt after that would
    /// arrive at an *unknown* key again — the key is only stored once a session
    /// is up. So the acceptance is carried across the password prompt, the way
    /// the typed password used to be carried across the key prompt before the
    /// two changed order.
    ///
    /// Carried as the key itself and not as a yes, which is what makes it safe
    /// to keep past a failed attempt: a later attempt asks for that exact key
    /// to come back rather than accepting whatever answers. A typo in the
    /// password therefore costs a retry and not a second look at the
    /// fingerprint.
    @PerceptionIgnored private var acceptedHostKey: String?

    /// The last size the view actually reported, as opposed to the one the
    /// terminal object carries before it has ever been laid out.
    @PerceptionIgnored private var measuredSize: (columns: Int, rows: Int)?

    /// How much of the grid's top the retracting title bar lies over, in points,
    /// as the screen draws it — 0 when the bar is the system's and the terminal
    /// starts below it. Set by ``TerminalScreen``; read once per connection, by
    /// ``connect(password:acceptHostKey:)``.
    @PerceptionIgnored var titleBarOverlap: CGFloat = 0

    /// Set once a shell has come up on this tab, so the rows left clear under
    /// the title bar are written at the first login and never again.
    @PerceptionIgnored private var hasLoggedIn = false

    @PerceptionIgnored private var forwarder: PortForwarder?
    @PerceptionIgnored private var forwardingTask: Task<Void, Never>?

    @PerceptionIgnored private let hosts: HostRepository
    @PerceptionIgnored private let keys: SSHKeyRepository
    @PerceptionIgnored private var sshSession: SSHSession?
    /// Where the terminal's bytes come from, and the only thing here that knows
    /// which protocol carries them. See ``TerminalTransport``.
    @PerceptionIgnored private var transport: TerminalTransport?

    /// Whether writing into our own grid would put us out of step with the far
    /// end — which is to say whether the screen belongs to the server.
    ///
    /// Asked of the host's switch before there is a transport and corrected from
    /// the transport as soon as there is one, because the title bar's countdown
    /// is shorter than a login: a bar that only retracts once mosh has answered
    /// has already covered the first frame. A session that fell back to SSH is
    /// corrected the same way, so the two cannot drift apart.
    private(set) var barWouldHideOutput: Bool

    /// Whole seconds since the far end was last heard from, 0 while in contact.
    ///
    /// Zero for ever under SSH, which cannot tell: TCP acknowledges and
    /// retransmits below us, so silence there is indistinguishable from a server
    /// with nothing to say. A protocol that keeps its own session alive with a
    /// heartbeat knows exactly, and owes the screen the number.
    private(set) var outOfContactSeconds = 0

    /// What the SSH half of a connection needs to carry on with, kept while the
    /// user is asked what to do about mosh.
    private struct Dialled {
        let session: SSHSession
        /// The machine that was dialled: this tab's host, or its bastion.
        let host: Host
        let params: SSHConnectionParams
        let planner: ConnectionPlanner
        /// The `ssh` line to type into a bastion once there is a shell, if this
        /// is one.
        let hopCommand: String?
    }

    @PerceptionIgnored private var dialled: Dialled?

    /// The machine that was dialled and what it was dialled with, kept so the
    /// port forwardings can be started again without asking anything. See
    /// ``bringTheForwardingsBack()``.
    @PerceptionIgnored private var lastDialled: (host: Host, params: SSHConnectionParams)?
    @PerceptionIgnored private var readerTask: Task<Void, Never>?
    @PerceptionIgnored private var contactTask: Task<Void, Never>?
    @PerceptionIgnored private var bridge: TerminalDelegateBridge?

    init(host: Host, hosts: HostRepository, keys: SSHKeyRepository) {
        self.host = host
        self.hosts = hosts
        self.keys = keys
        self.title = host.label
        self.barWouldHideOutput = host.mosh
        // SwiftTerm's view with one gesture fewer — see SessionTerminalView.
        //
        // Narrowing the paste item to "only when the
        // clipboard holds text" — which the Android build does, and which
        // avoids a menu entry that does nothing — would mean overriding
        // canPerformAction, and SwiftTerm declares it `public` rather than
        // `open`, so a subclass outside that module cannot. Paste itself is
        // already there; only the refinement is out of reach without a one-line
        // change upstream.
        self.terminalView = SessionTerminalView.make(frame: CGRect(x: 0, y: 0, width: 400, height: 300))

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

        touch = TerminalTouchHandling(
            terminal: terminalView,
            send: { [weak self] bytes in self?.send(bytes) },
            zoom: { [weak self] size in self?.zoom(to: size) }
        )
    }

    // MARK: - View settings

    /// Applies the terminal settings that live on the view. Called on every pass
    /// of the screen; each part does nothing when its value has not changed.
    func applyViewSettings(doubleTap: AppPreferences.DoubleTapAction, invertedScroll: Bool, scrollback: Int) {
        touch?.apply(doubleTap: doubleTap)
        touch?.apply(invertedScroll: invertedScroll)
        touch?.apply(scrollback: scrollback)
    }

    /// What to do when the terminal is tapped, once the tap is confirmed as a
    /// single one. The screen hands in the handler that brings the auto-hiding
    /// title bar back; nil while the bar is fixed.
    func setTapHandler(_ handler: (() -> Void)?) {
        touch?.onTap = handler
    }

    #if DEBUG
    /// The gesture arbitration behind the auto-hiding title bar, for the tests
    /// that pin it. Nothing outside them reads this.
    var tapGesturesForTesting: (tap: UITapGestureRecognizer, waitsFor: UIGestureRecognizer?)? {
        guard let touch else { return nil }
        return (touch.tapRecognizer, touch.tapWaitsFor)
    }
    #endif

    /// Sets this tab's text size, as a pinch does.
    func zoom(to size: CGFloat) {
        zoomedFontSize = size
        terminalView.font = TerminalFont.regular(size: size)
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
        // The Trust button has only a yes to hand back, so the key it was
        // shown is taken from the question still on screen.
        if acceptHostKey, case .needsHostKeyApproval(let info, _) = phase {
            acceptedHostKey = info.knownHostsLine
        }
        phase = .connecting

        // Nothing stored means the password is asked for from *inside* the
        // connection, once the server has said who it is and what it will
        // accept: that is the only moment its banner exists, and it also means
        // the host has answered before anyone types anything. See
        // ``SSHAuth/deferred``.
        let planner = ConnectionPlanner(hosts: hosts, keys: keys)

        // Mosh cannot be tunnelled, so a host whose first hop has mosh is
        // reached from the other end: this session is made *to that bastion*,
        // and the rest of the way is typed into it as one `ssh` line. See
        // ``ConnectionPlanner/bastionWalk(for:)``.
        let walk = await planner.bastionWalk(for: host)

        // The machine this session dials and logs in to. Everything about the
        // login belongs to it — credentials, host key, legacy ciphers, which
        // `mosh-server` is started — while everything about the destination
        // still belongs to `host`: the `ssh` line, the connection count, the
        // SFTP tab, the port forwardings.
        let dialled = walk?.bastion ?? host

        let auth: SSHAuth
        do {
            auth = try await resolveAuth(typedPassword: password, for: dialled) ?? .deferred
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
        let params = await planner.params(
            for: dialled,
            destination: walk == nil ? nil : host,
            auth: auth,
            hostKeyPolicy: hostKeyPolicy(acceptHostKey: acceptHostKey, for: dialled)
        )

        do {
            let session = try await SSHSession.connect(params)

            // Mosh when the machine being dialled asks for it and there is no
            // chain left for SSH to walk. Mosh has no channels, so a chain
            // cannot be tunnelled through it; a host whose *first hop* has mosh
            // is reached from the other end, which is the bastion and is its own
            // piece of work.
            if dialled.mosh, params.jumpHosts.isEmpty {
                let mosh = await startMosh(
                    on: session, dialled: dialled, params: params, geometry: geometry,
                    hopCommand: walk?.line
                )
                if let mosh {
                    await settle(
                        session: session, dialled: dialled, transport: mosh,
                        params: params, planner: planner, hopCommand: walk?.line
                    )
                }
                return
            }

            let channel = try await session.openShell(
                columns: geometry.columns,
                rows: geometry.rows
            )

            // The seam. Above this line the app is opening an SSH shell; below
            // it, it asks a transport for bytes and does not know which one it
            // has. The sink is given once and is good for the life of the tab,
            // because the emulator is owned here and not by the view.
            let transport = SSHTerminalTransport(channel: channel, apply: sink())
            await settle(
                session: session, dialled: dialled, transport: transport,
                params: params, planner: planner, hopCommand: walk?.line
            )
        } catch SSHError.needsPassword(let banner) {
            phase = .needsPassword(banner: banner)
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
    /// - Parameter dialled: the machine being logged in to, which is this tab's
    ///   host or — when the chain is walked from a bastion — the bastion. The
    ///   credentials are that machine's, because it is the one asking.
    private func resolveAuth(typedPassword: String?, for dialled: Host) async throws -> SSHAuth? {
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

        // Two different failures, and they used to be one. A host pointing at a
        // key that has been deleted is not the same as a key whose material
        // will not come back out of the Keychain, and neither is "the passphrase
        // may be wrong" — which is what the shared case said, about a passphrase
        // the user was never asked for.
        if let keyId = dialled.keyId {
            guard let key = try await keys.fetch(id: keyId) else {
                throw SSHError.keyNotFound
            }
            guard let pem = KeychainCrypto.privateKeyPEM(for: key) else {
                throw SSHError.keyUnreadable
            }
            // No passphrase: a key is unlocked when it is imported and stored
            // unlocked, so there is never one to supply here. A key imported by
            // a released version is still encrypted and cannot authenticate,
            // which is what the warning in the key list is about.
            return .publicKey(privateKeyPEM: pem)
        }

        return KeychainCrypto.password(for: dialled).map { SSHAuth.password($0) }
    }

    private func hostKeyPolicy(acceptHostKey: Bool, for dialled: Host) -> HostKeyPolicy {
        if acceptHostKey { return .acceptOnce }
        if let accepted = acceptedHostKey { return .requireMatch(accepted) }
        guard let stored = dialled.knownHostsEntry, !stored.isEmpty else { return .promptIfUnknown }
        return .requireMatch(stored)
    }

    /// Records the connection: pins the host key the first time, and stamps the
    /// last-connected time as the Android app does.
    ///
    /// The key belongs to the machine that presented it, which is the bastion
    /// when there is one; the connection count belongs to the row the person
    /// tapped, which is this tab's host either way.
    private func persistAfterConnect(hostKey: HostKeyInfo, dialled: Host) async throws {
        if let id = dialled.id, dialled.knownHostsEntry?.isEmpty ?? true {
            try await hosts.updateKnownHostsEntry(id: id, to: hostKey.knownHostsLine)
        }
        if let id = host.id {
            try await hosts.recordConnection(id: id)
        }
    }

    /// Begins the session as many rows down as the title bar covers, before the
    /// first byte of the login banner arrives.
    ///
    /// A login that prints two lines left both of them under a bar that has yet
    /// to retract, and the screen read as empty until it did. Nothing is sent to
    /// the server and nothing is lost: the cursor simply starts further down.
    ///
    /// Everything shifts, not only what would have been hidden. The padding has
    /// to be written before there is any output to measure, and shifting the
    /// whole banner costs nothing, while shifting the minimum would deliberately
    /// keep its first lines under the bar.
    ///
    /// Only ever at the first login of a tab. A reconnect — the app coming back
    /// to a link that died while it was away, or Reconnect on a dropped one —
    /// arrives with the previous session's output on screen, and blank rows
    /// pushed into the middle of that would be noise rather than room. Android
    /// draws the same line, from the other side: its padding is in `connect` and
    /// not in `startReading`, "which also runs for a session being picked up
    /// again after the app was away: that one already has its output on screen
    /// and must not be nudged". A retry that never got as far as a shell has
    /// written nothing, so it still counts as the first.
    ///
    /// Internal rather than private so a test can call it: the rows it writes
    /// are the whole of the feature, and the alternative — a live login, read
    /// back from the screen — is not available. The terminal is a `textView` to
    /// XCUITest but its `value` is empty, measured on 18/10/2026: a UI test
    /// asserting on the grid's text failed with nothing in it to assert on.
    func startBelowTheTitleBar() {
        guard !hasLoggedIn else { return }
        hasLoggedIn = true

        let rows = Self.blankRowsUnderTheBar(
            overlap: titleBarOverlap,
            viewHeight: terminalView.bounds.height,
            rows: terminalView.getTerminal().rows,
            screenIsSynchronised: transport?.screenIsSynchronised == true
        )
        guard rows > 0 else { return }
        terminalView.feed(text: String(repeating: "\n", count: rows))
    }

    /// How many blank rows go in before the first byte: as many as the bar
    /// covers, or **none at all** when the screen is the far side's.
    ///
    /// The second half is not a refinement. Writing into our own emulator under
    /// mosh puts us out of step with the frames being computed against it:
    /// mosh's first frame homes the cursor, clears the screen and paints at
    /// absolute positions, so these rows are wiped — and if they land *after*
    /// that clear, our screen sits three rows below the one the server is
    /// differencing against, and every frame after it is corrupt. Measured on
    /// Android, not argued: it showed up as "sometimes three blank rows,
    /// sometimes not, and then the typed line jumps to the top after a few
    /// words", because it was a race as well as a mistake. The bar is kept out
    /// of the way instead — see ``barWouldHideOutput``.
    static func blankRowsUnderTheBar(
        overlap: CGFloat,
        viewHeight: CGFloat,
        rows: Int,
        screenIsSynchronised: Bool
    ) -> Int {
        guard !screenIsSynchronised else { return 0 }
        return rowsCovered(by: overlap, viewHeight: viewHeight, rows: rows)
    }

    /// How many whole rows something `points` tall, lying over the top of the
    /// grid, hides.
    ///
    /// Rounded up, because a row half covered is a row that cannot be read, and
    /// never the whole grid: a bar taller than the terminal — a split view
    /// narrowed to nothing — must still leave a row to write on.
    ///
    /// The cell height comes from dividing, as everywhere else in the terminal:
    /// SwiftTerm's own cell size is not reachable from here. Zero before the
    /// first layout, when there is no height to divide and so no answer.
    static func rowsCovered(by points: CGFloat, viewHeight: CGFloat, rows: Int) -> Int {
        guard points > 0, viewHeight > 0, rows > 0 else { return 0 }
        let cell = viewHeight / CGFloat(rows)
        return min(Int((points / cell).rounded(.up)), rows - 1)
    }

    // MARK: - Mosh

    /// Starts `mosh-server` over the SSH session just opened and hands back the
    /// transport that rides it, or nil when the user is being asked about it.
    ///
    /// The SSH session is kept either way, which is the difference from the
    /// stock client: it goes on carrying SFTP, the port forwardings, the agent
    /// and the command history, and it is the one that started the server.
    private func startMosh(
        on session: SSHSession,
        dialled: Host,
        params: SSHConnectionParams,
        geometry: (columns: Int, rows: Int),
        hopCommand: String?
    ) async -> MoshTerminalTransport? {
        var started: MoshTerminalTransport?
        let failure: MoshBootstrap.Unavailable

        do {
            let handover = try await MoshBootstrap.start(
                on: session,
                // The address SSH actually reached, not the name that was typed:
                // `mosh-server -s` listens on that one address of that one
                // family, and resolving the name again is a guess the lab has
                // already watched fail.
                dialled: session.dialledAddress ?? params.hostname,
                program: dialled.moshCommand,
                ports: dialled.moshPorts
            )
            let mosh = try MoshTerminalTransport(handover: handover, apply: sink())
            started = mosh
            mosh.start()
            // Before the first datagram, so the server paints for the terminal
            // we have rather than for the 80x24 it would otherwise assume.
            mosh.resize(columns: geometry.columns, rows: geometry.rows)

            if await mosh.awaitFirstContact() { return mosh }

            // Nothing came back. There is no handshake in the protocol and no
            // error from the far end for a blocked path, so silence is the whole
            // symptom — and what is worth saying about it is where we were
            // trying to talk.
            failure = MoshBootstrap.Unavailable(
                reason: .noUDPAnswer, detail: await mosh.peerDescription()
            )
        } catch let unavailable as MoshBootstrap.Unavailable {
            failure = unavailable
        } catch {
            // The exec channel refused, the key would not decode: from here it
            // is the same thing as a server that said something unreadable, and
            // the detail is what there is to go on.
            failure = MoshBootstrap.Unavailable(
                reason: .noConnectLine, detail: error.localizedDescription
            )
        }

        started?.close()
        self.dialled = Dialled(
            session: session,
            host: dialled,
            params: params,
            planner: ConnectionPlanner(hosts: hosts, keys: keys),
            hopCommand: hopCommand
        )
        phase = .moshUnavailable(failure)
        return nil
    }

    /// The first of the two answers to ``Phase/moshUnavailable(_:)``: open the
    /// shell on the session that is already there and carry on as an SSH tab.
    func continueOverSSH() async {
        guard case .moshUnavailable = phase, let dialled else { return }
        self.dialled = nil
        phase = .connecting

        do {
            let geometry = await measuredGeometry()
            let channel = try await dialled.session.openShell(
                columns: geometry.columns,
                rows: geometry.rows
            )
            let transport = SSHTerminalTransport(channel: channel, apply: sink())
            await settle(
                session: dialled.session,
                dialled: dialled.host,
                transport: transport,
                params: dialled.params,
                planner: dialled.planner,
                hopCommand: dialled.hopCommand
            )
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The other answer: nothing here is wanted, and the session that was opened
    /// to start the server is not kept for anything else.
    func leaveAfterMoshFailed() {
        dialled = nil
        disconnect()
    }

    // MARK: - The line typed into a bastion

    /// The `ssh` line waiting to be typed, and when it was armed.
    ///
    /// On the session rather than on the screen, so a switch between tabs in the
    /// seconds before it goes out does not leave a session parked on its
    /// bastion.
    @PerceptionIgnored private var pendingHopCommand: String?
    @PerceptionIgnored private var hopArmedAt = Date.distantPast
    @PerceptionIgnored private var hopLastOutputAt = Date.distantPast
    @PerceptionIgnored private var hopTask: Task<Void, Never>?

    /// Types the line once the login has settled.
    ///
    /// Settled means the output has stopped, not that a prompt has been
    /// recognised: recognising one is a heuristic over somebody else's PS1, and
    /// waiting for silence needs to know nothing about the shell. A login that
    /// has had nothing to say for ``hopQuiet`` is ready to be typed into,
    /// whatever its prompt looks like.
    ///
    /// Two things can trigger it and the first wins: the silence, and
    /// ``hopGrace`` for a login that never stops printing. Typing blind costs
    /// little — authentication is long over, so the only thing listening is a
    /// shell, and a shell keeps a line that arrives while it is still greeting.
    /// The one thing that must not happen is typing it twice, which is why the
    /// line is taken rather than read.
    private func armHopCommand(_ command: String) {
        pendingHopCommand = command
        hopArmedAt = Date()
        // Nothing may ever arrive — a shell that has already said everything it
        // had to say — so the silence is counted from here and not only from the
        // last chunk.
        hopLastOutputAt = Date()

        hopTask?.cancel()
        hopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                // A session that has gone takes its line with it. Returning
                // rather than carrying on: there is nobody left to type into,
                // and a loop that kept going would wake twenty times a second
                // for as long as the app lived.
                guard let self else { return }
                // No `await` on either: a `Task` started inside a main-actor
                // class stays on it, which is also why typing the line from here
                // is allowed at all.
                guard self.hopIsDue() else { continue }
                self.typePendingHopCommand()
                return
            }
        }
    }

    private func hopIsDue() -> Bool {
        guard pendingHopCommand != nil else { return true }
        let now = Date()
        return now.timeIntervalSince(hopLastOutputAt) >= Self.hopQuiet
            || now.timeIntervalSince(hopArmedAt) >= Self.hopGrace
    }

    /// The login has just printed something, so the silence starts again from
    /// now.
    ///
    /// Cheap on purpose: it runs on the path that applies host bytes, and does
    /// nothing at all once the line has been typed.
    private func noteHopOutput() {
        guard pendingHopCommand != nil else { return }
        hopLastOutputAt = Date()
    }

    /// Types the pending line, once. Later calls find nothing left to do.
    ///
    /// Written straight to the transport rather than through ``send(text:)``:
    /// this is not a keystroke, and counting it as one would put a line nobody
    /// typed into the suggestion list the person may be looking at.
    private func typePendingHopCommand() {
        guard let command = pendingHopCommand else { return }
        pendingHopCommand = nil
        hopTask?.cancel()
        hopTask = nil
        transport?.write(Data((command + "\n").utf8))
    }

    /// How long a login has to be silent before it is taken for ready.
    static let hopQuiet: TimeInterval = 0.2

    /// And how long it is given to go quiet at all.
    static let hopGrace: TimeInterval = 5

    // MARK: - Connected

    /// Everything that happens once there is a transport, whichever one it is.
    ///
    /// One place for it because there are now three ways in — an SSH login, a
    /// mosh session that answered, and a mosh session that did not and was
    /// carried on over SSH — and the order of these steps has been settled by
    /// use.
    private func settle(
        session: SSHSession,
        dialled: Host,
        transport: TerminalTransport,
        params: SSHConnectionParams,
        planner: ConnectionPlanner,
        hopCommand: String?
    ) async {
        self.dialled = nil
        self.lastDialled = (host: dialled, params: params)
        self.sshSession = session
        self.transport = transport
        phase = .connected
        // Asked of the transport rather than remembered, so a session that fell
        // back to SSH does not keep the answer the host's switch gave.
        barWouldHideOutput = transport.screenIsSynchronised
        // Nothing else needs the credential now: the history is read on this
        // very session, so there is no second login to hold one for. The
        // key is written down a few lines below, so the acceptance that was
        // standing in for it is finished too.
        passwordForThisAttempt = nil
        acceptedHostKey = nil

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

        try? await persistAfterConnect(hostKey: session.hostKey, dialled: dialled)
        await planner.persistJumpHostKeys(session.newJumpHostKeys, for: host)
        startForwarding(params)
        startBelowTheTitleBar()
        startReading(from: transport)
        if let mosh = transport as? MoshTerminalTransport { watchMoshInDebug(mosh) }
        // Last, and only once there is a shell to type it into.
        if let hopCommand { armHopCommand(hopCommand) }
    }

    /// Where host bytes go: the emulator, and then whatever is waiting on the
    /// far end having said something.
    ///
    /// One place for it because all three roads in need the same sink, and
    /// because it is the only path that can tell when a login has gone quiet.
    private func sink() -> TerminalSink {
        { [weak self] bytes in
            self?.terminalView.feed(byteArray: ArraySlice(bytes))
            self?.noteHopOutput()
            self?.noteEcho()
        }
    }

    // MARK: - Measuring a keystroke, in a debug build only

    /// When something was last typed and has not been answered yet.
    @PerceptionIgnored private var typedAt: Date?

    @PerceptionIgnored private var diagnosticTask: Task<Void, Never>?

    private func noteKeystroke() {
        #if DEBUG
        if typedAt == nil { typedAt = Date() }
        #endif
    }

    /// The far end has answered: how long that took, and over what.
    ///
    /// Measured for **either** transport, which is the whole point of it. The
    /// comparison that decides whether phase 6b is worth writing — the eight
    /// screens of history — is the same device, the same network and the same
    /// finger, with SSH as the ruler; Android's figures were a median of 97 ms
    /// over mosh against 72 over SSH, and 115 before its own screen history.
    /// Read it with the phone attached:
    ///
    ///     log stream --predicate 'process == "SSHBorg"' | grep -E 'Terminal|Mosh'
    ///
    /// ⚠️ A reply the emulator sends by itself — an answer to a device query —
    /// comes through the same delegate as the keyboard and cannot be told apart
    /// here, so it starts a measurement of its own. There are a handful of them
    /// in a session, mostly during the login, and they are noise in a median
    /// rather than a reason to trust a single line.
    private func noteEcho() {
        #if DEBUG
        guard let typed = typedAt else { return }
        typedAt = nil
        let milliseconds = Int(Date().timeIntervalSince(typed) * 1000)
        NSLog(
            "Terminal: echo=%dms %@",
            milliseconds,
            transport?.screenIsSynchronised == true ? "mosh" : "ssh"
        )
        #endif
    }

    /// In a debug build, one line every two seconds about how a mosh session is
    /// going.
    ///
    /// The lab can measure a keystroke against a real server from a desktop; it
    /// cannot say what the same session costs on somebody's phone, and Android's
    /// first field report was "half a second a character" where its lab said
    /// seventeen milliseconds. This is how that gap gets a number instead of a
    /// theory. Nothing in a release build, and nothing in the line that is
    /// anybody's business but the session's own health — no key, no address, no
    /// host name.
    private func watchMoshInDebug(_ mosh: MoshTerminalTransport) {
        #if DEBUG
        diagnosticTask?.cancel()
        diagnosticTask = Task { [weak mosh] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let mosh, mosh.isConnected else { return }
                NSLog("Mosh: %@", mosh.diagnosticLine())
            }
        }
        #endif
    }

    // MARK: - Streaming

    /// Starts the transport and waits for it to end.
    ///
    /// The bytes do not come through here any more: the transport pushes them at
    /// the sink it was built with, which is what lets a protocol whose session
    /// must be answered on time deliver them on a thread of its own. What is
    /// left is the end, and what to do about it.
    private func startReading(from transport: TerminalTransport) {
        // Whatever this transport knows about being out of contact, passed on to
        // the screen. SSH knows nothing, the number stays at zero, and no line
        // is ever shown.
        contactTask?.cancel()
        outOfContactSeconds = 0
        if let seconds = transport.outOfContactSeconds {
            contactTask = Task { [weak self] in
                for await value in seconds {
                    guard let self else { return }
                    await MainActor.run { self.outOfContactSeconds = value }
                }
            }
        }

        readerTask?.cancel()
        readerTask = Task { [weak self] in
            let end = await transport.run()
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.handleStreamEnded(end) }
        }
    }

    private func handleStreamEnded(_ end: TerminalEnd) {
        guard case .connected = phase else { return }

        // A clean exit and a dropped link both land here, and which it was is
        // the transport's judgement rather than this screen's — under SSH it is
        // whether an exit status arrived, which carries a ⚠️ about killed shells
        // worth reading before changing anything (``SSHTerminalTransport/run()``).
        //
        // A dropped link is the case that deserves words: it used to be the
        // silent one, while an ordinary goodbye was reported as `exit status 1`,
        // which read like a fault.
        let endedCleanly = end == .cleanExit

        // A shell that exited on its own is finished, and reconnecting it would
        // undo what the user just did by typing `exit`.
        endedByRemote = endedCleanly
        phase = .disconnected(reason: Self.disconnectionReason(for: end))

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
            let alive = await sshSession?.isAlive() ?? false
            guard Self.needsRedialAfterBeingAway(
                screenIsSynchronised: transport?.screenIsSynchronised == true,
                sshIsAlive: alive
            ) else {
                if !alive { await bringTheForwardingsBack() }
                return
            }
            endedByRemote = false
            phase = .disconnected(reason: nil)
            await reconnectAutomatically()

        case .disconnected:
            await reconnectAutomatically()

        // Nothing to do while connecting, and the three questions are already in
        // front of the user.
        //
        // The mosh one is the odd member: the SSH session it kept to carry on
        // with may not have survived being away, in which case answering
        // "continue over SSH" fails and says so, with a Retry. Better than
        // taking the question down and dialling again behind the user's back,
        // which would ask it a second time anyway.
        case .connecting, .needsPassword, .needsHostKeyApproval, .moshUnavailable, .failed:
            return
        }
    }

    /// What the panel says under "Disconnected", or nil for a shell that exited
    /// on its own and takes its tab with it.
    ///
    /// The sentence first, because it is the one that says what happened in
    /// anybody's language, and then whatever the transport knows — which under
    /// mosh is the line this whole protocol's diagnostics were written for, and
    /// under SSH is the channel's own word for how its stream ended. It lands in
    /// the overlay's technical slot, with a Copy button, which is where a number
    /// somebody is going to paste into an issue belongs.
    static func disconnectionReason(for end: TerminalEnd) -> String? {
        guard case .lost(_, let detail) = end else { return nil }

        let sentence = String(localized: .terminalConnectionLost)
        guard let detail, !detail.isEmpty else { return sentence }
        return sentence + "\n\n" + detail
    }

    /// Whether a tab coming back from being away has to be dialled again.
    ///
    /// Under SSH, being away kills the connection — iOS suspends the app within
    /// about thirty seconds — and a new shell is the only thing on offer. That
    /// is why the reconnection is announced in the scrollback: whatever was
    /// running is gone, with its working directory and its environment.
    ///
    /// **A synchronised screen changes the answer.** The terminal lives on the
    /// server and the session is kept alive by the loop, so coming back it is
    /// the same terminal, with the same programs still running in it — which is
    /// the whole reason mosh is worth more here than on Android, where a
    /// foreground service keeps an SSH session alive anyway. So the tab is left
    /// exactly as it is, and nothing is announced, because nothing happened to
    /// it.
    ///
    /// ⚠️ What *is* lost is our SSH session, and with it the port forwardings,
    /// the forwarded agent and the command history, until the host is opened
    /// again. Dialling it again quietly in the background is the remaining half
    /// of this and is written down in PIANO.md: it has to be done without
    /// asking anything, or a password prompt appears over a terminal that is
    /// working perfectly.
    static func needsRedialAfterBeingAway(screenIsSynchronised: Bool, sshIsAlive: Bool) -> Bool {
        if screenIsSynchronised { return false }
        return !sshIsAlive
    }

    /// Brings the port forwardings back for a tab that survived being away.
    ///
    /// Only a mosh tab ever gets here: an SSH one is dialled again from scratch,
    /// and `startForwarding` runs as part of that.
    ///
    /// The forwardings have a session of their own — ``PortForwarder/start(_:params:)``
    /// dials one — so they died with the network while the terminal did not, and
    /// nothing else would ever start them again. The terminal's own session is
    /// *not* dialled again: it is read once, at login, for the command history,
    /// and the only other thing it answers is whether it is alive.
    ///
    /// Everything here is on the condition that it can be done **without asking
    /// anything**: stored credentials only and a host key already pinned. A tab
    /// whose terminal is working perfectly must not grow a password prompt over
    /// it, and a password someone typed by hand is deliberately not kept for
    /// this — the same rule ``reconnectAutomatically()`` follows. When it cannot
    /// be done the forwardings stay off until the host is opened again, which is
    /// what the guide says about mosh.
    ///
    /// ⚠️ The forwarded agent cannot come back this way and is not attempted.
    /// `SSH_AUTH_SOCK` inside the mosh session points at a socket belonging to
    /// the SSH session that started `mosh-server`, and that session is the one
    /// that died; a new one would have a new socket, which the running shell
    /// knows nothing about.
    private func bringTheForwardingsBack() async {
        guard let last = lastDialled else { return }

        // The row as it stands now: the host key was pinned after these params
        // were built, which is exactly the case this has to work in.
        var record = last.host
        if let id = last.host.id, let fresh = try? await hosts.fetch(id: id) { record = fresh }

        let planner = ConnectionPlanner(hosts: hosts, keys: keys)
        let auth = await planner.storedAuth(for: record)
        let pinned = record.knownHostsEntry ?? ""

        guard Self.forwardingsCanComeBack(
            forwardings: last.params.portForwardings.count,
            hasStoredCredentials: auth != nil,
            hasPinnedHostKey: !pinned.isEmpty
        ), let auth else { return }

        var params = last.params
        params.auth = auth
        params.hostKeyPolicy = .requireMatch(pinned)

        // The old listeners first: they are still bound to the local ports the
        // new ones want, and a forwarder whose session is dead keeps them.
        forwardingTask?.cancel()
        forwarder?.stop()
        forwarder = nil
        startForwarding(params)
    }

    /// Whether the port forwardings can be started again without asking
    /// anything.
    ///
    /// Three conditions, and each of them is a refusal to put a question over a
    /// working terminal. Something to forward at all; a credential that is
    /// stored, because a password someone typed by hand is deliberately not kept
    /// for this; and a host key already pinned, because the alternative is a
    /// fingerprint to approve that nobody asked to see.
    static func forwardingsCanComeBack(
        forwardings: Int,
        hasStoredCredentials: Bool,
        hasPinnedHostKey: Bool
    ) -> Bool {
        forwardings > 0 && hasStoredCredentials && hasPinnedHostKey
    }

    /// Reconnects when it can be done without asking anything.
    ///
    /// It deliberately does not reuse a password the user typed by hand. Keeping
    /// one in memory for the life of the app to make this seamless is a trade
    /// worth making explicitly rather than by default, so a host without a saved
    /// credential asks again — which the password prompt already handles.
    private func reconnectAutomatically() async {
        guard !closedByUser, !endedByRemote else { return }

        // No pre-flight check on the credential any more, and that is the fix.
        //
        // There used to be one here, and it sent *both* of its failures to the
        // password prompt: "nothing saved to reconnect with", which is a fair
        // question, and "the key would not load", which is not — that one asked
        // for a password on a host configured with a key, with nothing on screen
        // saying why. The compiler had been pointing at it for a while: `try?`
        // flattens the double optional, so the `auth != nil` beside it was
        // always true and warned as much.
        //
        // `connect()` already tells the two apart — nothing stored becomes a
        // question the server itself raises, `.needsPassword`, and a throw
        // becomes `.failed` with the reason — so the decision lives in one
        // place instead of being made twice and disagreeing.
        //
        // What that check also guaranteed still holds, structurally rather than
        // by inspection: a password typed by hand is never reused here, because
        // `passwordForThisAttempt` is cleared the moment the shell comes up and
        // nothing puts it back.
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
        noteKeystroke()
        transport?.write(data)
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
        transport?.resize(columns: columns, rows: rows)
    }

    // MARK: - Teardown

    func disconnect() {
        closedByUser = true
        passwordForThisAttempt = nil
        acceptedHostKey = nil
        readerTask?.cancel()
        readerTask = nil
        contactTask?.cancel()
        contactTask = nil
        outOfContactSeconds = 0
        diagnosticTask?.cancel()
        diagnosticTask = nil
        typedAt = nil
        hopTask?.cancel()
        hopTask = nil
        pendingHopCommand = nil
        transport?.close()
        transport = nil
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
    ///
    /// On the terminal's own connection, which is the whole point. It used to
    /// open a second one — a second handshake, a second authentication, the
    /// whole jump-host chain again, one more attempt in `fail2ban`'s count, and
    /// a second prompt for anyone whose server asks a question — to read three
    /// small files that this session is already authorised to read. Android
    /// removed the same second login on 19/09/2026.
    func loadHistory(preferences: AppPreferences) async {
        // ⚠️ Every exit below is silent, and that cost a day: "the suggestion
        // bar never appears" carried no information about which of five places
        // it stopped at. Instrumenting them temporarily is what found the real
        // cause, which was none of them. If this needs debugging again, name the
        // exits again before guessing at them.
        guard preferences.historySuggestions else { return }
        guard let session = sshSession else { return }

        guard let files = try? await SFTPQuickRead.readFromHome(
            CommandHistory.candidatePaths,
            on: session
        ) else {
            return
        }

        history = CommandHistory.merging(
            CommandHistory.candidatePaths.compactMap { name in
                files[name].map(CommandHistory.parse)
            }
        )

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
