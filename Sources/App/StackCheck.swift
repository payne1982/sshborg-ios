// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CSSH2
import Foundation
import GRDB
import SwiftTerm
import UIKit

/// Phase 0 smoke test.
///
/// All three dependencies are non-trivial to integrate: libssh2 is compiled from
/// source against OpenSSL, GRDB links SQLite, and SwiftTerm ships Metal shaders.
/// This check answers the only question that matters at this stage — does the
/// stack compile, link, and run on a device? — without waiting for real features.
///
/// Delete this once phase 3 replaces `RootView` with the hosts screen.
@MainActor
enum StackCheck {

    struct Outcome: Identifiable {
        let id = UUID()
        let component: String
        let detail: String
        let ok: Bool
    }

    static func runAll() -> [Outcome] {
        [checkLibssh2(), checkGRDB(), checkSwiftTerm()]
    }

    /// Initialises libssh2 and reads back its compiled version.
    static func checkLibssh2() -> Outcome {
        let rc = libssh2_init(0)
        guard rc == 0 else {
            return Outcome(
                component: "libssh2",
                detail: "libssh2_init() returned \(rc)",
                ok: false
            )
        }
        defer { libssh2_exit() }

        guard let version = libssh2_version(0) else {
            return Outcome(component: "libssh2", detail: "libssh2_version() is NULL", ok: false)
        }
        return Outcome(component: "libssh2", detail: String(cString: version), ok: true)
    }

    /// Opens an in-memory database and queries the SQLite version.
    static func checkGRDB() -> Outcome {
        do {
            let queue = try DatabaseQueue()
            let version = try queue.read { db in
                try String.fetchOne(db, sql: "SELECT sqlite_version()")
            }
            guard let version else {
                return Outcome(component: "GRDB / SQLite", detail: "no result", ok: false)
            }
            return Outcome(component: "GRDB / SQLite", detail: "SQLite \(version)", ok: true)
        } catch {
            return Outcome(component: "GRDB / SQLite", detail: "\(error)", ok: false)
        }
    }

    /// Instantiates a `TerminalView` and reads back its computed geometry.
    static func checkSwiftTerm() -> Outcome {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let terminal = view.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows
        return Outcome(
            component: "SwiftTerm",
            detail: "\(cols)×\(rows) grid",
            ok: cols > 0 && rows > 0
        )
    }
}
