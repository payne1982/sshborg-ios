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
        case needsPassword(banner: String?)
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
    /// existing name, a folder that could not be emptied. The browser stays
    /// usable and reports it, in full: which files, what the server said, and
    /// which ones were never reached. Cleared when the report is closed.
    var report: ErrorReport?

    /// What is waiting to be moved, and where it was cut from. Nil when nothing
    /// is.
    ///
    /// It lives here, on the browser, rather than on the screen: the browser is
    /// kept per host by ``SFTPBrowsers``, so a cut survives a trip to a terminal
    /// tab and back. Android had to move the same state onto its session object
    /// for exactly this reason — and for the other one, which holds here too: a
    /// cut belongs to one server. Pasting it onto another host would be a
    /// transfer, and SFTP cannot move a byte between two servers at all.
    private(set) var pendingCut: Cut?

    /// Raised when a paste finds names already taken in the destination, and
    /// answered by ``resolveMove(_:)``. The screen asks the question.
    var moveConflict: MoveConflict?

    /// The names the pending paste found taken, kept between the question and
    /// the answer so the second pass does not have to ask the server again.
    @PerceptionIgnored private var takenByPendingPaste: Set<String> = []

    /// Entries cut from one directory, waiting to be pasted into another.
    struct Cut: Equatable {
        let directory: String
        let entries: [SFTPEntry]
    }

    /// A name in the destination that something already holds.
    ///
    /// `folder` is what takes the Overwrite button away, and it is true when
    /// **either** side of any collision is a directory: POSIX `rename(2)`
    /// replaces a directory only when it is empty, nothing in SFTP merges two of
    /// them, and `mv` itself answers "Directory not empty". A button that
    /// replaced some names and refused others — depending on something the user
    /// cannot see from the listing — would be worse than no button.
    enum MoveConflict: Equatable {
        case single(name: String, folder: Bool)
        case batch(taken: Int, total: Int, folder: Bool)
    }

    enum MoveDecision {
        case overwrite
        case keepBoth
        case cancel
    }

    @PerceptionIgnored private let hosts: HostRepository
    @PerceptionIgnored private let keys: SSHKeyRepository
    @PerceptionIgnored private var session: SFTPSession?

    /// The password typed for the connection currently being made. See the same
    /// property on `TerminalSession`: one attempt can ask two questions, and
    /// trusting the host key must not throw away the password given a moment
    /// earlier. Dropped as soon as the browser is up, and on disconnect.
    @PerceptionIgnored private var passwordForThisAttempt: String?

    /// The `known_hosts` line the user accepted, carried across the password
    /// prompt that now follows it. ``TerminalSession/acceptedHostKey`` explains
    /// why it is the key and not a yes.
    @PerceptionIgnored private var acceptedHostKey: String?

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
        // The key the Trust button agreed to, read from the question it
        // answered. See ``TerminalSession/acceptedHostKey`` for why it is kept.
        if acceptHostKey, case .needsHostKeyApproval(let info, _) = phase {
            acceptedHostKey = info.knownHostsLine
        }
        phase = .connecting

        // Nothing stored means the server is the one that asks, once it has
        // said who it is and what it will accept — which is also the only
        // moment its banner exists. Same as the terminal; see ``SSHAuth/deferred``.
        let auth: SSHAuth
        do {
            auth = try await resolveAuth(typedPassword: password) ?? .deferred
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
            acceptedHostKey = nil
            await refresh()
        } catch SSHError.needsPassword(let banner) {
            phase = .needsPassword(banner: banner)
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
        if let accepted = acceptedHostKey { return .requireMatch(accepted) }
        guard let stored = host.knownHostsEntry, !stored.isEmpty else { return .promptIfUnknown }
        return .requireMatch(stored)
    }

    private func persistAfterConnect(hostKey: HostKeyInfo) async throws {
        guard let id = host.id else { return }
        if host.knownHostsEntry?.isEmpty ?? true {
            try await hosts.updateKnownHostsEntry(id: id, to: hostKey.knownHostsLine)
        }
        try await hosts.recordConnection(id: id)
    }

    func disconnect() {
        passwordForThisAttempt = nil
        acceptedHostKey = nil
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
            report = ErrorReport(
                title: String(localized: .errorCannotListDirectory),
                name: (path as NSString).lastPathComponent,
                error: error
            )
        }
    }

    // MARK: - Acting

    func createDirectory(named name: String) async {
        await perform(.errorCreateDirectoryFailed, naming: name) { session in
            try await session.createDirectory(at: self.join(self.path, name))
        }
    }

    func rename(_ entry: SFTPEntry, to newName: String) async {
        await perform(.errorRenameFailed, naming: entry.name) { session in
            try await session.rename(
                from: self.join(self.path, entry.name),
                to: self.join(self.path, newName)
            )
        }
    }

    // MARK: - Moving

    /// Takes entries for a move. Replaces whatever was waiting before, as a
    /// second Ctrl-X does.
    func cut(_ entries: [SFTPEntry]) {
        guard !entries.isEmpty else { return }
        pendingCut = Cut(directory: path, entries: entries)
    }

    func cancelCut() {
        pendingCut = nil
    }

    /// Moves what was cut into the directory on screen, with SFTP alone.
    ///
    /// Every step is a rename, performed by the server on its own filesystem:
    /// nothing is read, nothing is written, and nothing crosses the network. The
    /// protocol has no copy request — OpenSSH 9 added `copy-data@openssh.com`
    /// and libssh2 does not expose it — so a copy would mean fetching the bytes
    /// to the phone and sending them back, which is a different feature at a
    /// different price. Hence move, and only move.
    ///
    /// The destination is checked before every rename, never left to the server.
    /// See ``SFTPSession/rename(from:to:)`` for what the two platforms otherwise
    /// do differently, which is the whole reason this is written this way.
    func paste() async {
        guard let session, let cut = pendingCut else { return }
        let destination = path

        // Already where it was asked to go. The clipboard has served; saying so
        // with an error would be pedantry.
        guard cut.directory != destination else {
            pendingCut = nil
            return
        }

        // A folder cannot be moved into itself or anywhere below itself. The
        // server's answer to that is a bare failure, so it is caught here where
        // there is something useful to say — and it is a prefix comparison, the
        // same test Android makes.
        let intoItself = cut.entries.filter {
            Self.wouldMoveIntoItself($0, from: cut.directory, to: destination)
        }
        guard intoItself.isEmpty else {
            report = ErrorReport(
                title: String(localized: .errorMoveFailed),
                failures: intoItself.map {
                    FileFailure(
                        name: $0.name,
                        message: String(localized: .sftpMoveIntoItself),
                        detail: ""
                    )
                }
            )
            return
        }

        // One `lstat` per entry — not `stat`, which would call a dangling
        // symlink's name free.
        var taken: Set<String> = []
        var collidesWithFolder = false
        for entry in cut.entries {
            guard let existing = try? await session.lstat(join(destination, entry.name)) else { continue }
            taken.insert(entry.name)
            if existing.isDirectory || entry.isDirectory { collidesWithFolder = true }
        }

        guard !taken.isEmpty else {
            await move(cut, into: destination, taken: [], decision: .overwrite)
            return
        }

        takenByPendingPaste = taken
        moveConflict = cut.entries.count == 1
            ? .single(name: cut.entries[0].name, folder: collidesWithFolder)
            : .batch(taken: taken.count, total: cut.entries.count, folder: collidesWithFolder)
    }

    /// The answer to ``moveConflict``. Cancelling leaves the cut where it is, so
    /// the same things can be pasted somewhere else without cutting them again.
    func resolveMove(_ decision: MoveDecision) async {
        let taken = takenByPendingPaste
        takenByPendingPaste = []
        moveConflict = nil

        guard decision != .cancel, let cut = pendingCut else { return }
        await move(cut, into: path, taken: taken, decision: decision)
    }

    private func move(
        _ cut: Cut,
        into destination: String,
        taken: Set<String>,
        decision: MoveDecision
    ) async {
        guard let session else { return }

        var failures: [FileFailure] = []
        var notAttempted: [String] = []

        for (index, entry) in cut.entries.enumerated() {
            let source = join(cut.directory, entry.name)
            do {
                if !taken.contains(entry.name) {
                    try await session.rename(from: source, to: join(destination, entry.name))
                } else if decision == .keepBoth {
                    let free = try await freeName(for: entry, in: destination, using: session)
                    try await session.rename(from: source, to: join(destination, free))
                } else {
                    try await replace(
                        source: source,
                        destination: join(destination, entry.name),
                        using: session
                    )
                }
            } catch {
                failures.append(FileFailure(name: entry.name, error: error))
                if Self.endsTheRun(error) {
                    notAttempted = cut.entries.dropFirst(index + 1).map(\.name)
                    break
                }
            }
        }

        pendingCut = nil
        await refresh()

        if !failures.isEmpty || !notAttempted.isEmpty {
            report = ErrorReport(
                title: String(localized: .errorMoveFailed),
                failures: failures,
                notAttempted: notAttempted
            )
        }
    }

    /// Overwriting, done here rather than asked of the server: park what is in
    /// the way under a free name, move the source into place, delete the parked
    /// copy — and if the move fails, put the parked file back where it was.
    ///
    /// Every rename in that sequence has a free destination, which is what makes
    /// it behave the same under both of this project's SFTP clients, and at no
    /// point does the user's file exist under no name at all.
    ///
    /// Only ever reached for a file: a folder collision does not offer this.
    private func replace(source: String, destination: String, using session: SFTPSession) async throws {
        let parked = "\(destination).sshborg-replaced-\(Int(Date().timeIntervalSince1970 * 1000))"
        try await session.rename(from: destination, to: parked)
        do {
            try await session.rename(from: source, to: destination)
        } catch {
            // Best effort, and deliberately not reported over the top of the
            // error that caused it: the original failure is the one the user
            // needs, and if this one fails too the parked name is in the listing
            // where it can be seen.
            try? await session.rename(from: parked, to: destination)
            throw error
        }
        try? await session.removeFile(at: parked)
    }

    /// Whether moving this entry out of `source` and into `destination` would
    /// put a folder inside itself or inside its own subtree.
    ///
    /// The server's answer to that is a bare failure, so it is asked here. The
    /// trailing slash in the prefix test is the whole of the arithmetic: without
    /// it, moving `/home/notes` into `/home/notesbook` would be refused, because
    /// one path begins with the other without being below it.
    ///
    /// A symlinked directory is not a directory for this purpose: moving a link
    /// into the tree it points at moves one name, and nothing is nested.
    static func wouldMoveIntoItself(_ entry: SFTPEntry, from source: String, to destination: String) -> Bool {
        guard entry.isDirectory && !entry.isSymlink else { return false }
        let root = source.hasSuffix("/") ? source + entry.name : source + "/" + entry.name
        return destination == root || destination.hasPrefix(root + "/")
    }

    /// A name split where a copy's number goes: `report.txt` → `report` + `.txt`.
    ///
    /// Two rules, both of which Android follows and both of which have a wrong
    /// answer worth avoiding: a leading dot is not an extension, so `.bashrc`
    /// becomes `.bashrc(1)` and not `(1).bashrc`; and a folder is never split,
    /// so `backup.2026` becomes `backup.2026(1)`.
    static func split(_ entry: SFTPEntry) -> (base: String, ext: String) {
        guard !entry.isDirectory,
              let dot = entry.name.lastIndex(of: "."),
              dot != entry.name.startIndex
        else { return (entry.name, "") }
        return (String(entry.name[entry.name.startIndex..<dot]), String(entry.name[dot...]))
    }

    /// "name(1)", "name(2)", … the first the destination does not already hold.
    /// The same shape a second download of the same file gets.
    ///
    /// A leading dot is not an extension: `.bashrc` becomes `.bashrc(1)` and not
    /// `(1).bashrc`, which is why the dot has to be past the first character.
    /// Folders are not split at all.
    private func freeName(
        for entry: SFTPEntry,
        in directory: String,
        using session: SFTPSession
    ) async throws -> String {
        let (base, ext) = Self.split(entry)

        // Bounded, unlike Android's, which loops until it finds one. A server
        // that answered "taken" to everything would hang the paste with no way
        // out, and this costs one `lstat` per try: at a thousand the name is not
        // the problem any more.
        for n in 1...1000 {
            let candidate = "\(base)(\(n))\(ext)"
            if try await session.lstat(join(directory, candidate)) == nil { return candidate }
        }
        throw SSHError.library(code: 0, message: "no free name for \(entry.name)")
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
    /// Deletes entries, emptying folders first — and does not stop at the first
    /// one that refuses.
    ///
    /// A permission denied on the third of ten files used to end the whole
    /// operation, leaving seven files the user had asked about untouched and
    /// unmentioned. Now every entry is attempted, each failure is collected with
    /// its own name, and only a lost connection stops the run: what is left then
    /// is listed as not attempted, because a batch that stopped halfway must not
    /// look like one that finished.
    func delete(_ entries: [SFTPEntry]) async {
        guard let session else { return }

        var failures: [FileFailure] = []
        var notAttempted: [String] = []

        for (index, entry) in entries.enumerated() {
            let target = join(path, entry.name)
            do {
                if entry.isDirectory && !entry.isSymlink {
                    try await Self.removeTree(at: target, using: session)
                } else {
                    try await session.removeFile(at: target)
                }
            } catch {
                failures.append(FileFailure(name: entry.name, error: error))

                if Self.endsTheRun(error) {
                    notAttempted = entries.dropFirst(index + 1).map(\.name)
                    break
                }
            }
        }

        await refresh()

        if !failures.isEmpty || !notAttempted.isEmpty {
            report = ErrorReport(
                title: String(localized: .errorDeleteFailed),
                failures: failures,
                notAttempted: notAttempted
            )
        }
    }

    /// Whether there is any point in trying the next file.
    ///
    /// A server refusing one file says nothing about the next one; a connection
    /// that has gone says everything about all of them, and hammering a dead
    /// session with the rest of the batch only delays the report.
    private static func endsTheRun(_ error: Error) -> Bool {
        guard let error = error as? SSHError else { return false }
        switch error {
        case .notConnected, .connectionFailed, .timedOut, .cancelled:
            return true
        default:
            return false
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
    private func perform(
        _ title: LocalizedStringResource,
        naming name: String,
        _ action: @escaping (SFTPSession) async throws -> Void
    ) async {
        guard let session else { return }
        do {
            try await action(session)
            await refresh()
        } catch {
            report = ErrorReport(title: String(localized: title), name: name, error: error)
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

extension SFTPModel.MoveConflict {

    /// Whether a folder is on either side of any collision, which is what takes
    /// the Overwrite button away.
    var involvesFolder: Bool {
        switch self {
        case .single(_, let folder), .batch(_, _, let folder): return folder
        }
    }

    /// What to say about it. The two non-folder sentences are the ones an upload
    /// conflict already uses — the situation is the same one, a name taken in
    /// the folder on the server, and it was already translated for all ten.
    var message: String {
        switch self {
        case .single(let name, let folder):
            return String(localized: folder ? .sftpMoveFolderExists : .sftpUploadConflictMessage)
                .replacingOccurrences(of: "%1$@", with: name)
        case .batch(let taken, let total, let folder):
            return String(localized: folder ? .sftpMoveBatchFolderExists : .sftpUploadBatchConflictMessage)
                .replacingOccurrences(of: "%1$d", with: "\(taken)")
                .replacingOccurrences(of: "%2$d", with: "\(total)")
        }
    }
}
