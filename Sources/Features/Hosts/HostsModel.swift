// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Backs the host list: keeps hosts and groups in sync with the database and
/// arranges them into the sections the screen draws.
///
/// Counterpart of the Android `HostsViewModel`, with `ValueObservation` doing
/// what Room's `Flow` queries did.
@MainActor
@Observable
final class HostsModel {

    private(set) var hosts: [Host] = []
    private(set) var groups: [HostGroup] = []

    @ObservationIgnored private let hostRepository: HostRepository
    @ObservationIgnored private let groupRepository: HostGroupRepository

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
