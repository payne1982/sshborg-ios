// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads the integration-test target out of the environment.
///
/// The four integration suites each had their own copy of this. They are the
/// same three lines, and keeping four of them is how they came to disagree —
/// which already happened once with the shell marker heuristic, where one copy
/// was fixed and the others were not.
///
/// **Why the password can arrive base64-encoded.** The values reach the test
/// process as xcodebuild build settings, and Xcode *evaluates* build setting
/// values: a `$` in a password is read as a reference to another setting, and
/// what the test receives is not what was passed. Measured on a real password
/// containing `$`: sixteen characters in, thirty-three characters out. Base64
/// has no character Xcode treats specially, so `…_B64` is the reliable channel
/// and the plain variable stays supported for passwords that survive the trip.
enum SSHTestCredentials {

    struct Target {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    /// A variable, ignoring both an empty value and an unexpanded `$(…)`
    /// placeholder — which is what arrives when the scheme forwards a variable
    /// that was never given on the command line.
    static func setting(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name],
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    /// The password, preferring the base64 form when both are present.
    static func password() -> String? {
        if let encoded = setting("SSHBORG_TEST_PASSWORD_B64"),
           let data = Data(base64Encoded: encoded),
           let decoded = String(data: data, encoding: .utf8),
           !decoded.isEmpty {
            return decoded
        }
        return setting("SSHBORG_TEST_PASSWORD")
    }

    /// The configured target, or `nil` when the suite should skip itself.
    static func target() -> Target? {
        guard let host = setting("SSHBORG_TEST_HOST"),
              let username = setting("SSHBORG_TEST_USER"),
              let password = password()
        else { return nil }

        return Target(
            host: host,
            port: setting("SSHBORG_TEST_PORT").flatMap(Int.init) ?? 22,
            username: username,
            password: password
        )
    }

    /// Message for `XCTSkip`, naming what is missing so a skipped suite does not
    /// look like a passing one.
    static let skipReason = """
        No SSH target configured. Set SSHBORG_TEST_HOST, SSHBORG_TEST_USER and \
        either SSHBORG_TEST_PASSWORD or SSHBORG_TEST_PASSWORD_B64.
        """
}
