// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// Drives one remote file browser: its connection, where it is, and what it
/// shows. Counterpart of the Android `SftpViewModel`.
@MainActor
@Perceptible
final class SFTPModel {

    /// Mirrors ``TerminalSession/Phase``, since both screens face the same
    /// questions before a connection exists.
    enum Phase: Equatable {
        case connecting
        case browsing
        case needsPassword
        case needsHostKeyApproval(HostKeyInfo, isChange: Bool)
        case failed(String)
    }

    /// A copy that this browser keeps up to date, not a snapshot: the two
    /// per-host things it can change — the last visited directory and whether
    /// dotfiles are shown — are both written back through it. Were it a `let`,
    /// each write would save the other one's stale value over the top.
    private(set) var host: Host

    private(set) var phase: Phase = .connecting
    private(set) var path = "/"
    private(set) var entries: [SFTPEntry] = []
    private(set) var isLoading = false

    /// Set when an action fails but the connection survives — a rename onto an
    /// existing name, say. The browser stays usable and just reports it.
    var actionError: String?

    @PerceptionIgnored private let hosts: HostRepository
    @PerceptionIgnored private let keys: SSHKeyRepository
    @PerceptionIgnored private var session: SFTPSession?

    /// The password typed for the connection currently being made. See the same
    /// property on `TerminalSession`: one attempt can ask two questions, and
    /// trusting the host key must not throw away the password given a moment
    /// earlier. Dropped as soon as the browser is up, and on disconnect.
    @PerceptionIgnored private var passwordForThisAttempt: String?

    /// Exposed so the screen can hand it to the transfer manager. `nil` until
    /// the connection is up.
    var activeSession: SFTPSession? { session }

    init(host: Host, hosts: HostRepository, keys: SSHKeyRepository) {
        self.host = host
        self.hosts = hosts
        self.keys = keys
    }

    // MARK: - Connecting

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

        // Through the planner so a jump host applies here too: browsing files on
        // a machine only reachable through a bastion is exactly the case where
        // it matters. Port forwarding rules come along in the parameters and are
        // simply not started — those belong to the terminal session.
        let planner = ConnectionPlanner(hosts: hosts, keys: keys)
        let params = await planner.params(
            for: host,
            auth: auth,
            hostKeyPolicy: hostKeyPolicy(acceptHostKey: acceptHostKey)
        )

        do {
            let session = try await SFTPSession.connect(params)
            self.session = session

            try? await persistAfterConnect(hostKey: session.hostKey)
            await planner.persistJumpHostKeys(session.newJumpHostKeys, for: host)

            path = startingPath(home: session.homePath)
            phase = .browsing
            passwordForThisAttempt = nil
            await refresh()
        } catch SSHError.unknownHostKey(let info) {
            phase = .needsHostKeyApproval(info, isChange: false)
        } catch SSHError.hostKeyMismatch(let info) {
            phase = .needsHostKeyApproval(info, isChange: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Where to open, honouring the host's start-directory setting.
    private func startingPath(home: String) -> String {
        switch host.parsedSFTPStartMode {
        case .home:
            return home
        case .fixed, .last:
            let stored = host.sftpStartDir?.trimmed
            return (stored?.isEmpty ?? true) ? home : stored!
        }
    }

    private func resolveAuth(typedPassword: String?) async throws -> SSHAuth? {
        if let typedPassword, !typedPassword.isEmpty {
            passwordForThisAttempt = typedPassword
        }
        if let carried = passwordForThisAttempt, !carried.isEmpty {
            return .password(carried)
        }
        // Same split as `TerminalSession.resolveAuth`, for the same reason: a
        // deleted key and a Keychain that will not answer are different things
        // to be told about, and neither is a wrong passphrase.
        if let keyId = host.keyId {
            guard let key = try await keys.fetch(id: keyId) else {
                throw SSHError.keyNotFound
            }
            guard let pem = KeychainCrypto.privateKeyPEM(for: key) else {
                throw SSHError.keyUnreadable
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

    private func persistAfterConnect(hostKey: HostKeyInfo) async throws {
        guard let id = host.id else { return }
        if host.knownHostsEntry?.isEmpty ?? true {
            try await hosts.updateKnownHostsEntry(id: id, to: hostKey.knownHostsLine)
        }
        try await hosts.updateLastConnected(id: id)
    }

    func disconnect() {
        passwordForThisAttempt = nil
        session?.disconnect()
        session = nil
    }

    // MARK: - Navigating

    func navigate(into entry: SFTPEntry) async {
        guard entry.isDirectory else { return }
        await navigate(to: join(path, entry.name))
    }

    func navigateUp() async {
        guard path != "/" else { return }
        var parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty { parent = "/" }
        await navigate(to: parent)
    }

    /// Moves to a directory, ignoring taps that arrive while a move is already
    /// under way.
    ///
    /// Dropped rather than queued, which is what the Android build settled on:
    /// someone tapping twice on a slow link means "go here", not "go here and
    /// then somewhere else", and queueing walked several levels at once.
    ///
    /// The reason differs from Android's, which is worth saying because the fix
    /// looks like a copy and is not. There, concurrent listings corrupted the
    /// JSch channel and dropped the whole connection; here every libssh2 call is
    /// already serialised on the session queue, so the stream is safe. What is
    /// not safe is the *order*: two listings in flight can finish in either one,
    /// leaving the entries of one directory on screen under the path of another.
    func navigate(to absolutePath: String) async {
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }

        path = absolutePath.isEmpty ? "/" : absolutePath
        await refresh()
        await rememberLastVisited()
    }

    /// Persists the current directory when the host is set to reopen where it
    /// left off. Silent on failure: it is a convenience, not the user's task.
    private func rememberLastVisited() async {
        guard host.parsedSFTPStartMode == .last, host.id != nil else { return }
        host.sftpStartDir = path
        await persistHost()
    }

    /// Whether dotfiles are listed. Off by default, per host, and kept on the
    /// host row so the choice is still there next time — the toolbar toggle and
    /// the host editor's switch write the same field.
    var showsHiddenFiles: Bool { host.sftpShowHidden }

    /// Flips dotfile visibility. The filtering happens where the list is drawn,
    /// so this never refetches: the entries are all already here.
    func toggleHiddenFiles() async {
        host.sftpShowHidden.toggle()
        await persistHost()
    }

    /// What the list shows: the server's entries, minus dotfiles when the host
    /// says to hide them, in the order the settings ask for.
    ///
    /// Both steps are display-only, on purpose. Flipping either is then instant
    /// and never refetches, and — the part that matters — everything else that
    /// walks a directory still sees all of it. A folder download must bring the
    /// dotfiles down with it; hiding them is a way of looking at a directory,
    /// not a way of having one.
    ///
    /// ".." never reaches here: the screen draws it as a row of its own, so it
    /// cannot be filtered out or sorted away from the top.
    static func visibleEntries(
        _ entries: [SFTPEntry],
        showingHidden: Bool,
        directoriesFirst: Bool
    ) -> [SFTPEntry] {
        let shown = showingHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }

        // A listing already arrives directories-first; only the other order
        // needs doing, and it is by name alone, as on Android.
        guard !directoriesFirst else { return shown }
        return shown.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Writes back only the two columns this browser owns, onto whatever the row
    /// says now. Silent on failure: these are conveniences, not the user's task.
    ///
    /// Re-reading first is not caution for its own sake. Connecting pins the
    /// host key and the jump hops' keys through column-specific updates, which
    /// this object never sees; saving our own copy wholesale would write those
    /// back as they were before the connection — dropping a freshly pinned key
    /// on the first directory change, and asking the user to trust the server
    /// again next time.
    private func persistHost() async {
        guard let id = host.id,
              var stored = try? await hosts.fetch(id: id) else { return }
        stored.sftpStartDir = host.sftpStartDir
        stored.sftpShowHidden = host.sftpShowHidden
        _ = try? await hosts.save(stored)
    }

    /// True while a directory change is in flight. Not `isLoading`: that also
    /// covers a plain refresh, and a refresh must not block navigation.
    private(set) var isNavigating = false

    func refresh() async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            entries = try await session.list(path)
        } catch {
            // A listing that fails leaves the previous contents on screen: an
            // empty list would suggest an empty directory, which is a lie.
            actionError = error.localizedDescription
        }
    }

    // MARK: - Acting

    func createDirectory(named name: String) async {
        await perform { session in
            try await session.createDirectory(at: self.join(self.path, name))
        }
    }

    func rename(_ entry: SFTPEntry, to newName: String) async {
        await perform { session in
            try await session.rename(
                from: self.join(self.path, entry.name),
                to: self.join(self.path, newName)
            )
        }
    }

    func delete(_ entry: SFTPEntry) async {
        await delete([entry])
    }

    /// Deletes entries, emptying folders first.
    ///
    /// SFTP's `rmdir` only removes an empty directory, so a folder has to be
    /// walked and cleared from the leaves up — which is what Android's
    /// `deleteRecursive` does, and without it deleting any non-empty folder
    /// simply failed.
    ///
    /// A symlinked directory is unlinked, not descended into: following it would
    /// delete whatever it points at, which is emphatically not what was asked.
    func delete(_ entries: [SFTPEntry]) async {
        await perform { session in
            for entry in entries {
                let target = self.join(self.path, entry.name)
                if entry.isDirectory && !entry.isSymlink {
                    try await Self.removeTree(at: target, using: session)
                } else {
                    try await session.removeFile(at: target)
                }
            }
        }
    }

    private static func removeTree(at path: String, using session: SFTPSession) async throws {
        for entry in try await session.list(path) {
            let child = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
            if entry.isDirectory && !entry.isSymlink {
                try await removeTree(at: child, using: session)
            } else {
                try await session.removeFile(at: child)
            }
        }
        try await session.removeDirectory(at: path)
    }

    /// Runs an action and refreshes, reporting failure without tearing the
    /// browser down.
    private func perform(_ action: @escaping (SFTPSession) async throws -> Void) async {
        guard let session else { return }
        do {
            try await action(session)
            await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Names already present here, so an upload can avoid clashing with one.
    var existingNames: Set<String> {
        Set(entries.map(\.name))
    }

    // MARK: - Paths

    /// Joins without ever producing a doubled slash, which some servers reject.
    func join(_ base: String, _ component: String) -> String {
        base == "/" ? "/\(component)" : "\(base)/\(component)"
    }

    /// The path split for a breadcrumb, each with the absolute path to jump to.
    var breadcrumb: [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var accumulated = ""

        for component in path.split(separator: "/") {
            accumulated += "/\(component)"
            result.append((String(component), accumulated))
        }
        return result
    }
}
