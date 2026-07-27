// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB
import SwiftUI

/// A named, colour-coded group of hosts.
///
/// The table is `host_groups`, not `groups`: GROUPS is an SQLite keyword.
struct HostGroup: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {

    static let databaseTableName = "host_groups"

    var id: Int64?
    var name: String

    /// ARGB colour, normally one of ``swatches``. Kept as an integer rather than
    /// a `Color` so the value round-trips through the shared JSON backup.
    var color: Int

    /// Whether the group's section is collapsed in the host list.
    var collapsed: Bool = false

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension HostGroup {

    /// Predefined group colours, readable as icon tints on both light and dark
    /// surfaces. Identical values and order to the Android app, so a group keeps
    /// its colour when a backup is restored across platforms.
    static let swatches: [Int] = [
        0xFFE5_3935, // red
        0xFFF5_7C00, // orange
        0xFFF9_A825, // amber
        0xFF43_A047, // green
        0xFF00_897B, // teal
        0xFF03_9BE5, // light blue
        0xFF5C_6BC0, // indigo
        0xFFAB_47BC, // purple
        0xFFEC_407A, // pink
        0xFF78_909C, // blue grey
    ]

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
    }

    var swiftUIColor: Color {
        Color(argb: color)
    }
}

extension Color {

    /// Builds a colour from a packed ARGB integer, the representation the
    /// Android app and the JSON backup both use.
    init(argb: Int) {
        let alpha = Double((argb >> 24) & 0xFF) / 255
        let red = Double((argb >> 16) & 0xFF) / 255
        let green = Double((argb >> 8) & 0xFF) / 255
        let blue = Double(argb & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
