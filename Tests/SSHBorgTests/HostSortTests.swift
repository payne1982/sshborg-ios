// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SSHBorg

/// The host list order (#16).
///
/// Every case here is arithmetic over a list, which is exactly the part of the
/// feature that a screenshot cannot check: whether the ends of a section refuse
/// a move, whether a second seeding pass finds anything left to do, and whether
/// the alphabetical order really does survive as the tiebreaker.
final class HostSortTests: XCTestCase {

    private func host(
        _ id: Int64,
        _ label: String,
        group: Int64? = nil,
        lastConnected: Int64? = nil,
        connectCount: Int = 0,
        position: Int? = nil
    ) -> Host {
        var host = Host(label: label, hostname: "h", username: "u")
        host.id = id
        host.groupId = group
        host.lastConnected = lastConnected
        host.connectCount = connectCount
        host.position = position
        return host
    }

    private func group(_ id: Int64, _ name: String, position: Int? = nil) -> HostGroup {
        var group = HostGroup(name: name, color: HostGroup.swatches[0])
        group.id = id
        group.position = position
        return group
    }

    // MARK: - Sorting

    /// The database already returns hosts by label, so this mode must hand the
    /// list straight back — including mixed case, which a re-sort here would
    /// arrange differently from SQLite.
    func testAlphabeticalReturnsTheListUntouched() {
        let hosts = [host(1, "zeta"), host(2, "Alpha"), host(3, "mid")]
        let sorted = HostSort.sortHosts(hosts, by: .alphabetical)
        XCTAssertEqual(sorted.map(\.label), ["zeta", "Alpha", "mid"])
    }

    func testRecentPutsNeverConnectedHostsLast() {
        let hosts = [
            host(1, "never"),
            host(2, "older", lastConnected: 1_000),
            host(3, "newest", lastConnected: 9_000),
        ]
        let sorted = HostSort.sortHosts(hosts, by: .recent)
        XCTAssertEqual(sorted.map(\.label), ["newest", "older", "never"])
    }

    func testMostUsedOrdersByCount() {
        let hosts = [host(1, "a", connectCount: 1), host(2, "b", connectCount: 9), host(3, "c")]
        let sorted = HostSort.sortHosts(hosts, by: .popular)
        XCTAssertEqual(sorted.map(\.label), ["b", "a", "c"])
    }

    /// The point of the stable sort. Three hosts nobody has ever connected to
    /// compare equal in both usage modes, and must come back in the order the
    /// list has always shown them rather than in whatever order the sort
    /// happens to leave them in.
    func testEqualHostsKeepTheirAlphabeticalOrder() {
        let hosts = [host(1, "alpha"), host(2, "beta"), host(3, "gamma")]
        for mode in [HostSort.recent, .popular, .manual] {
            let sorted = HostSort.sortHosts(hosts, by: mode)
            XCTAssertEqual(sorted.map(\.label), ["alpha", "beta", "gamma"], "\(mode)")
        }
    }

    /// Enough elements that an unstable sort would actually show it: Swift's
    /// introsort only switches away from insertion sort above twenty.
    func testStabilityHoldsOverALongList() {
        let hosts = (1...40).map { host(Int64($0), String(format: "host%02d", $0)) }
        let sorted = HostSort.sortHosts(hosts, by: .popular)
        XCTAssertEqual(sorted.map(\.label), hosts.map(\.label))
    }

    func testAHostWithNoPlaceSortsAfterOneThatHasOne() {
        let hosts = [host(1, "unplaced"), host(2, "second", position: 1), host(3, "first", position: 0)]
        let sorted = HostSort.sortHosts(hosts, by: .manual)
        XCTAssertEqual(sorted.map(\.label), ["first", "second", "unplaced"])
    }

    func testGroupsOnlyMoveInTheManualOrder() {
        let groups = [group(1, "b", position: 1), group(2, "a", position: 0)]
        XCTAssertEqual(HostSort.sortGroups(groups, by: .recent).map(\.name), ["b", "a"])
        XCTAssertEqual(HostSort.sortGroups(groups, by: .popular).map(\.name), ["b", "a"])
        XCTAssertEqual(HostSort.sortGroups(groups, by: .manual).map(\.name), ["a", "b"])
    }

    // MARK: - Seeding

    func testSeedingNumbersEachSectionFromZero() {
        let hosts = [
            host(1, "u1"), host(2, "u2"),
            host(3, "g1", group: 7), host(4, "g2", group: 7),
        ]
        let writes = HostSort.seededHostPositions(hosts)
        XCTAssertEqual(writes.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(writes.map(\.position), [0, 1, 0, 1])
    }

    /// A host added after the order was seeded lands at the end of its section
    /// rather than renumbering everything around it.
    func testANewHostAppendsToItsSection() {
        let hosts = [host(1, "a", position: 0), host(2, "b", position: 1), host(3, "new")]
        let writes = HostSort.seededHostPositions(hosts)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].id, 3)
        XCTAssertEqual(writes[0].position, 2)
    }

    /// Seeding writes, and a write makes the observation fire again. The second
    /// pass has to be empty or the list would seed itself forever.
    func testASecondPassHasNothingToDo() {
        let hosts = [host(1, "a"), host(2, "b", group: 3)]
        var seeded = hosts
        for write in HostSort.seededHostPositions(hosts) {
            if let index = seeded.firstIndex(where: { $0.id == write.id }) {
                seeded[index].position = write.position
            }
        }
        XCTAssertTrue(HostSort.seededHostPositions(seeded).isEmpty)
    }

    func testGroupSeedingAppendsToTheEnd() {
        let groups = [group(1, "a", position: 0), group(2, "b"), group(3, "c")]
        let writes = HostSort.seededGroupPositions(groups)
        XCTAssertEqual(writes.map(\.id), [2, 3])
        XCTAssertEqual(writes.map(\.position), [1, 2])
    }

    // MARK: - Moving

    func testMovingSwapsTwoPositions() {
        let ordered: [(id: Int64, position: Int)] = [(10, 0), (20, 1), (30, 2)]
        let writes = try? XCTUnwrap(HostSort.swap(id: 20, by: -1, in: ordered))
        XCTAssertEqual(writes?.map(\.id), [20, 10])
        XCTAssertEqual(writes?.map(\.position), [0, 1])
    }

    /// The ends of a section are where a move stops: crossing into another
    /// group would mean changing the host's group, which is the editor's job.
    func testAMoveOffTheEndIsRefused() {
        let ordered: [(id: Int64, position: Int)] = [(10, 0), (20, 1)]
        XCTAssertNil(HostSort.swap(id: 10, by: -1, in: ordered))
        XCTAssertNil(HostSort.swap(id: 20, by: 1, in: ordered))
        XCTAssertNil(HostSort.swap(id: 99, by: -1, in: ordered))
    }

    /// Positions need not be contiguous — a delete leaves a gap — and a swap
    /// exchanges whatever numbers the two rows hold rather than assuming they
    /// differ by one.
    func testMovingAcrossAGapKeepsTheOrder() {
        let ordered: [(id: Int64, position: Int)] = [(10, 0), (20, 5), (30, 9)]
        let writes = try? XCTUnwrap(HostSort.swap(id: 30, by: -1, in: ordered))
        XCTAssertEqual(writes?.map(\.position), [5, 9])
    }

    // MARK: - The stored preference

    func testAnUnknownModeReadsAsTheDefault() {
        XCTAssertEqual(HostSort.mode(for: 2), .popular)
        XCTAssertEqual(HostSort.mode(for: 42), .alphabetical)
        XCTAssertEqual(HostSort.mode(for: -1), .alphabetical)
    }

    /// The raw values travel in the shared backup file, so they are the Android
    /// constants and not ours to renumber.
    func testRawValuesMatchAndroid() {
        XCTAssertEqual(HostSort.alphabetical.rawValue, 0)
        XCTAssertEqual(HostSort.recent.rawValue, 1)
        XCTAssertEqual(HostSort.popular.rawValue, 2)
        XCTAssertEqual(HostSort.manual.rawValue, 3)
    }
}
