// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Best-effort jailbreak check, the iOS counterpart of Android's `RootDetector`.
///
/// The point is the same as on Android: warn the user once that stored keys and
/// passwords are less safe on a compromised device. It is not a security
/// boundary — anything running with that much privilege can defeat this — so
/// nothing in the app should gate behaviour on the result beyond showing the
/// warning.
enum JailbreakDetector {

    static func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        // The simulator legitimately exposes many of these paths.
        return false
        #else
        return hasSuspiciousPaths() || canWriteOutsideSandbox()
        #endif
    }

    /// Files that only exist once a jailbreak has been installed. Covers both
    /// the classic layout and the `/var/jb` root used by rootless jailbreaks.
    private static let suspiciousPaths = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/usr/libexec/cydia",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/private/var/lib/apt",
        "/var/jb",
    ]

    private static func hasSuspiciousPaths() -> Bool {
        suspiciousPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// On an intact device the sandbox makes this write fail. If it succeeds,
    /// the sandbox is not being enforced.
    private static func canWriteOutsideSandbox() -> Bool {
        let path = "/private/\(UUID().uuidString)"
        do {
            try "sandbox check".write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }
}
