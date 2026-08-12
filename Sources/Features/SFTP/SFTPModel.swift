// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Drives one remote file browser: its connection, where it is, and what it
/// shows. Counterpart of the Android `SftpViewModel`.
@MainActor
@Observable
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

    let host: Host

    private(set) var phase: Phase = .connecting
    private(set) var path = "/"
    private(set) var entries: [SFTPEntry] = []
    private(set) var isLoading = false

    /// Set when an action fails but the connection survives — a rename onto an
    /// existing name, say. The browser stays usable and just reports it.
    var actionError: String?

    @ObservationIgnored private let hosts: HostRepository
    @ObservationIgnored private let keys: SSHKeyRepository
    @ObservationIgnored private var session: SFTPSession?

    /// The password typed for the connection currently being made. See the same
    /// property on `TerminalSession`: one attempt can ask two questions, and
    /// trusting the host key must not throw away the password given a moment
    /// earlier. Dropped as soon as the browser is up, and on disconnect.
    @ObservationIgnored private var passwordForThisAttempt: String?

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
        if let keyId = host.keyId {
            guard let key = try await keys.fetch(id: keyId),
                  let pem = KeychainCrypto.privateKeyPEM(for: key)
            else { throw SSHError.invalidPrivateKey }
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
        guard host.parsedSFTPStartMode == .last, let id = host.id else { return }
        var updated = host
        updated.id = id
        updated.sftpStartDir = path
        _ = try? await hosts.save(updated)
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
        await perform { session in
            let target = self.join(self.path, entry.name)
            if entry.isDirectory {
                try await session.removeDirectory(at: target)
            } else {
                try await session.removeFile(at: target)
            }
        }
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
