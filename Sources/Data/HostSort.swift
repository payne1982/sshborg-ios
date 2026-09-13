// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A row that can hold a place in the manual order.
///
/// Hosts and groups are moved by identical arithmetic, and this is what lets
/// the host list write it once instead of twice.
protocol Positioned {
    var id: Int64? { get }
    var position: Int? { get }
}

extension Host: Positioned {}
extension HostGroup: Positioned {}

/// Order of the host list (issue #16), ported from the Android `HostSort`.
///
/// Sorting happens here, in memory, and not in the query: the mode is a setting
/// the user flips at runtime, so re-sorting the list already in hand beats four
/// `ValueObservation`s and a swap between them.
///
/// Both functions take the lists **as the database returns them** — hosts by
/// label, groups by name — and every sort below keeps that order as the
/// tiebreaker, which is why ``alphabetical`` hands the input straight back
/// rather than re-sorting it: the list then looks exactly as it always has,
/// down to where the mixed-case labels fall.
///
/// The raw values are the integers the Android preference stores, because the
/// two apps share a backup file and the setting travels in it.
enum HostSort: Int, CaseIterable, Identifiable, Sendable {

    case alphabetical = 0
    case recent = 1
    case popular = 2
    case manual = 3

    var id: Int { rawValue }

    /// Anything else in the stored preference — an older file, a newer Android
    /// build with a fifth mode — reads as the default rather than as nothing.
    static func mode(for raw: Int) -> HostSort {
        HostSort(rawValue: raw) ?? .alphabetical
    }

    var localizedName: LocalizedStringResource {
        switch self {
        case .alphabetical: .settingsHostSortAlpha
        case .recent: .settingsHostSortRecent
        case .popular: .settingsHostSortPopular
        case .manual: .settingsHostSortManual
        }
    }

    // MARK: - Sorting

    /// Groups follow the manual order only. In every other mode they stay
    /// alphabetical so the section headers keep still and only the hosts inside
    /// them move.
    static func sortGroups(_ groups: [HostGroup], by mode: HostSort) -> [HostGroup] {
        guard mode == .manual else { return groups }
        return stableSorted(groups) { ($0.position ?? .max) < ($1.position ?? .max) }
    }

    static func sortHosts(_ hosts: [Host], by mode: HostSort) -> [Host] {
        switch mode {
        case .alphabetical:
            hosts
        // A host never connected to has no timestamp, and belongs at the
        // bottom of "recently used" rather than the top.
        case .recent:
            stableSorted(hosts) { ($0.lastConnected ?? .min) > ($1.lastConnected ?? .min) }
        case .popular:
            stableSorted(hosts) { $0.connectCount > $1.connectCount }
        case .manual:
            stableSorted(hosts) { ($0.position ?? .max) < ($1.position ?? .max) }
        }
    }

    /// A stable sort, which `sorted(by:)` is not.
    ///
    /// This is the one place the port could not copy Kotlin's shape. There
    /// `sortedBy` is documented as stable, and the Android implementation leans
    /// on it: alphabetical order is meant to survive as the tiebreaker in every
    /// mode, so two hosts connected to on the same day, or never, stay in the
    /// order the list has always shown them. Swift's sort is introsort and makes
    /// no such promise — equal elements may come back swapped, and worse, may
    /// swap differently between two runs over the same data, so the list would
    /// shuffle itself under the user for no visible reason.
    ///
    /// Decorating each element with its original index and falling back to that
    /// when neither side wins restores the guarantee.
    private static func stableSorted<T>(
        _ items: [T],
        by areInIncreasingOrder: (T, T) -> Bool
    ) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Seeding

    /// The positions to write so that every host in `hosts` has one.
    ///
    /// Called only while the manual order is in use, with the list in the order
    /// the *previous* mode was showing — so switching to manual moves nothing,
    /// and a host added later simply lands at the end of its section.
    ///
    /// Positions are scoped to a section, so each one gets its own run of
    /// numbers: the ungrouped block and every group count from zero.
    static func seededHostPositions(_ hosts: [Host]) -> [(id: Int64, position: Int)] {
        var result: [(id: Int64, position: Int)] = []
        let sections = Dictionary(grouping: hosts) { $0.groupId }

        // Sorted so the writes come out in a fixed order regardless of how the
        // dictionary happens to be laid out, which a test can then pin.
        for key in sections.keys.sorted(by: { ($0 ?? .min) < ($1 ?? .min) }) {
            let section = sections[key] ?? []
            var next = (section.compactMap(\.position).max() ?? -1) + 1
            for host in section where host.position == nil {
                guard let id = host.id else { continue }
                result.append((id, next))
                next += 1
            }
        }
        return result
    }

    /// The same for groups, which are one section of their own.
    static func seededGroupPositions(_ groups: [HostGroup]) -> [(id: Int64, position: Int)] {
        var next = (groups.compactMap(\.position).max() ?? -1) + 1
        var result: [(id: Int64, position: Int)] = []
        for group in groups where group.position == nil {
            guard let id = group.id else { continue }
            result.append((id, next))
            next += 1
        }
        return result
    }

    // MARK: - Moving

    /// The two writes that swap `id` with its neighbour `delta` steps away,
    /// or `nil` when there is no such neighbour.
    ///
    /// `ordered` is one section, already in position order and already filtered
    /// to the rows that have a position. Returning the writes rather than
    /// performing them keeps the arithmetic — the part that is easy to get
    /// wrong at the ends of a list — testable without a database.
    static func swap(
        id: Int64,
        by delta: Int,
        in ordered: [(id: Int64, position: Int)]
    ) -> [(id: Int64, position: Int)]? {
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let to = from + delta
        guard ordered.indices.contains(to) else { return nil }
        return [
            (ordered[from].id, ordered[to].position),
            (ordered[to].id, ordered[from].position),
        ]
    }
}
