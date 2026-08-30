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

    init(hosts hostRepository: HostRepository, groups groupRepository: HostGroupRepository) {
        self.hostRepository = hostRepository
        self.groupRepository = groupRepository
    }

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
                    }
                } catch {}
            }
            taskGroup.addTask { [groupRepository] in
                do {
                    for try await value in groupRepository.observeAll() {
                        await MainActor.run { self.groups = value }
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
        let knownGroupIDs = Set(groups.compactMap(\.id))

        // A host pointing at a group that no longer exists falls back to
        // ungrouped rather than disappearing. Odd imports can produce this.
        let ungrouped = hosts.filter { host in
            guard let groupId = host.groupId else { return true }
            return !knownGroupIDs.contains(groupId)
        }

        var result: [Section] = []
        if !ungrouped.isEmpty {
            result.append(Section(group: nil, hosts: ungrouped))
        }

        for group in groups {
            let members = hosts.filter { $0.groupId == group.id }
            result.append(Section(group: group, hosts: members))
        }

        return result
    }

    var isEmpty: Bool {
        hosts.isEmpty && groups.isEmpty
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
    /// last-connected stamp, which belongs to the original's history and not to
    /// a host nobody has connected to yet.
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
