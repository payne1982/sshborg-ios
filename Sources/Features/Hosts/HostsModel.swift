// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// Backs the host list: keeps hosts and groups in sync with the database and
/// arranges them into the sections the screen draws.
///
/// Counterpart of the Android `HostsViewModel`, with `ValueObservation` doing
/// what Room's `Flow` queries did.
@MainActor
@Perceptible
final class HostsModel {

    private(set) var hosts: [Host] = []
    private(set) var groups: [HostGroup] = []

    @PerceptionIgnored private let hostRepository: HostRepository
    @PerceptionIgnored private let groupRepository: HostGroupRepository
    @PerceptionIgnored private let preferences: AppPreferences

    init(
        hosts hostRepository: HostRepository,
        groups groupRepository: HostGroupRepository,
        preferences: AppPreferences
    ) {
        self.hostRepository = hostRepository
        self.groupRepository = groupRepository
        self.preferences = preferences
    }

    /// The order the list is drawn in (#16). Read through the preference so the
    /// screen redraws when it is changed in Settings, which is where it lives.
    var sortMode: HostSort { preferences.hostSortMode }

    /// Streams both tables until the caller's task is cancelled.
    ///
    /// An observation that throws is the end of that stream, not something the
    /// list can act on, so it simply stops updating rather than blanking out
    /// the hosts the user can still see.
    func observe() async {
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { [hostRepository] in
                do {
                    for try await value in hostRepository.observeAll() {
                        await MainActor.run { self.hosts = value }
                        await self.seedPositionsIfNeeded()
                    }
                } catch {}
            }
            taskGroup.addTask { [groupRepository] in
                do {
                    for try await value in groupRepository.observeAll() {
                        await MainActor.run { self.groups = value }
                        await self.seedPositionsIfNeeded()
                    }
                } catch {}
            }
        }
    }

    // MARK: - Sections

    /// One drawn section of the list.
    struct Section: Identifiable {
        /// `nil` for the ungrouped hosts, which are drawn first and without a
        /// header — so a user with no groups sees exactly a plain list.
        let group: HostGroup?
        let hosts: [Host]

        var id: Int64 { group?.id ?? -1 }
    }

    var sections: [Section] {
        let mode = sortMode
        // Both arrive from the database in alphabetical order and are re-sorted
        // here; see ``HostSort`` for why the sorting is not in the query.
        //
        // Sorting the whole list before splitting it is correct even though a
        // host's position is scoped to its section: filtering a sorted list
        // keeps the relative order within every section it is cut into.
        let sortedHosts = HostSort.sortHosts(hosts, by: mode)
        let sortedGroups = HostSort.sortGroups(groups, by: mode)
        let knownGroupIDs = Set(sortedGroups.compactMap(\.id))

        // A host pointing at a group that no longer exists falls back to
        // ungrouped rather than disappearing. Odd imports can produce this.
        let ungrouped = sortedHosts.filter { host in
            guard let groupId = host.groupId else { return true }
            return !knownGroupIDs.contains(groupId)
        }

        var result: [Section] = []
        if !ungrouped.isEmpty {
            result.append(Section(group: nil, hosts: ungrouped))
        }

        for group in sortedGroups {
            let members = sortedHosts.filter { $0.groupId == group.id }
            result.append(Section(group: group, hosts: members))
        }

        return result
    }

    var isEmpty: Bool {
        hosts.isEmpty && groups.isEmpty
    }

    // MARK: - The manual order

    /// The mode the list was showing before the current one.
    ///
    /// It is what the first seeding follows, so switching to the manual order
    /// moves nothing: the rows keep the arrangement the user was looking at
    /// when they chose it.
    @PerceptionIgnored private var previousMode: HostSort = .alphabetical

    /// Gives a position to every row that lacks one, but only while the manual
    /// order is actually in use.
    ///
    /// Called after each change to either table and whenever the mode changes.
    /// Seeding writes, which makes the observation fire again — and the second
    /// pass finds nothing to do, so it stops there rather than looping.
    ///
    /// Doing this lazily, instead of on insert, is what keeps every path that
    /// creates a host or a group — the editor, a clone, a restored backup —
    /// free of ordering logic.
    func seedPositionsIfNeeded() async {
        let mode = preferences.hostSortMode
        guard mode == .manual else {
            previousMode = mode
            return
        }

        let hostWrites = HostSort.seededHostPositions(HostSort.sortHosts(hosts, by: previousMode))
        let groupWrites = HostSort.seededGroupPositions(HostSort.sortGroups(groups, by: previousMode))
        if !hostWrites.isEmpty { try? await hostRepository.updatePositions(hostWrites) }
        if !groupWrites.isEmpty { try? await groupRepository.updatePositions(groupWrites) }
    }

    /// Moves a host one step up (`delta` of -1) or down (+1) within its own
    /// section.
    ///
    /// Crossing into another group would mean changing `groupId`, which is the
    /// host editor's job, so the ends of a section are simply where the move
    /// stops.
    func move(_ host: Host, by delta: Int) async {
        guard let id = host.id else { return }
        let section = ordered(hosts.filter { $0.groupId == host.groupId })
        guard let writes = HostSort.swap(id: id, by: delta, in: section) else { return }
        try? await hostRepository.updatePositions(writes)
    }

    /// The same, for a whole group section.
    func move(_ group: HostGroup, by delta: Int) async {
        guard let id = group.id else { return }
        guard let writes = HostSort.swap(id: id, by: delta, in: ordered(groups)) else { return }
        try? await groupRepository.updatePositions(writes)
    }

    /// The placed rows of one section, in position order.
    ///
    /// Rows without a position are left out rather than treated as last: a move
    /// swaps two positions, and a row that has none has nothing to swap. In the
    /// manual order there are none of these for longer than one seeding pass.
    private func ordered<T: Positioned>(_ rows: [T]) -> [(id: Int64, position: Int)] {
        rows
            .compactMap { row -> (id: Int64, position: Int)? in
                guard let id = row.id, let position = row.position else { return nil }
                return (id, position)
            }
            .sorted { $0.position < $1.position }
    }

    /// The tint for a host's icon: its own colour wins over its group's.
    func color(for host: Host) -> Int? {
        if let own = host.color { return own }
        guard let groupId = host.groupId else { return nil }
        return groups.first { $0.id == groupId }?.color
    }

    // MARK: - Mutations

    func delete(_ host: Host) async {
        try? await hostRepository.delete(host)
    }

    /// Copies a host into a new row and hands it back so the caller can open it
    /// in the editor. Ported from the Android `cloneHost`.
    ///
    /// Everything is copied verbatim — credentials, key, jump chain, port
    /// forwards, group, colour — because the whole point is to reuse a host's
    /// settings and change one detail like the port or the jump host. Three
    /// things do not survive: the id, so this is a new row; the label, which
    /// gains "(copy)" from the catalog rather than a string built here; and the
    /// last-connected stamp and its usage count, which belong to the original's
    /// history and not to a host nobody has connected to yet.
    ///
    /// The pinned host key comes along on purpose. The copy points at the same
    /// server, so the key that was verified for the original is the right one,
    /// and dropping it would raise a fingerprint prompt that teaches the user to
    /// wave prompts away.
    func duplicate(_ host: Host) async -> Host? {
        var copy = host
        copy.id = nil
        copy.label = String(localized: .hostCloneLabel)
            .replacingOccurrences(of: "%1$@", with: host.label)
        copy.lastConnected = nil
        // A copy starts unranked and unplaced, so it lands at the end of its
        // section rather than inheriting the original's turn in the order.
        copy.connectCount = 0
        copy.position = nil
        return try? await hostRepository.save(copy)
    }

    /// Deleting a group keeps its hosts: the repository detaches them in the
    /// same transaction, so they reappear as ungrouped rather than vanishing.
    func delete(_ group: HostGroup) async {
        try? await groupRepository.delete(group)
    }

    func toggleCollapsed(_ group: HostGroup) async {
        guard let id = group.id else { return }
        try? await groupRepository.setCollapsed(id: id, !group.collapsed)
    }
}
