// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// Chooses which key exchange, host key and cipher algorithms to offer.
///
/// The algorithm names are never hard-coded: they are read back from libssh2
/// with `libssh2_session_supported_algs`, then split into a modern group and a
/// legacy group. That way every name we hand to `libssh2_session_method_pref`
/// is guaranteed to exist in this build, and the lists follow the library
/// instead of drifting from it.
///
/// The two groups mirror the Android app, where the default JSch lists exclude
/// these algorithms and `allowLegacyCiphers` appends them back for old servers.
enum SSHAlgorithms {

    /// CBC ciphers and 3DES: broken or deprecated, but still all some old
    /// appliances speak. Matches `applyLegacyCiphers` on Android.
    static let legacyCiphers: Set<String> = [
        "aes128-cbc",
        "aes192-cbc",
        "aes256-cbc",
        "3des-cbc",
        "blowfish-cbc",
        "cast128-cbc",
        "arcfour",
        "arcfour128",
        "arcfour256",
    ]

    /// SHA-1 based key exchanges.
    static let legacyKeyExchanges: Set<String> = [
        "diffie-hellman-group14-sha1",
        "diffie-hellman-group-exchange-sha1",
        "diffie-hellman-group1-sha1",
    ]

    /// DSA, and SHA-1 signatures over RSA keys.
    static let legacyHostKeys: Set<String> = [
        "ssh-dss",
        "ssh-rsa",
    ]

    /// Applies the preference lists to a session. Must be called *before* the
    /// handshake, which is when libssh2 sends its algorithm proposal.
    static func applyPreferences(to session: OpaquePointer, allowLegacy: Bool) {
        apply(to: session, method: LIBSSH2_METHOD_KEX, legacy: legacyKeyExchanges, allowLegacy: allowLegacy)
        apply(to: session, method: LIBSSH2_METHOD_HOSTKEY, legacy: legacyHostKeys, allowLegacy: allowLegacy)
        apply(to: session, method: LIBSSH2_METHOD_CRYPT_CS, legacy: legacyCiphers, allowLegacy: allowLegacy)
        apply(to: session, method: LIBSSH2_METHOD_CRYPT_SC, legacy: legacyCiphers, allowLegacy: allowLegacy)
    }

    private static func apply(
        to session: OpaquePointer,
        method: Int32,
        legacy: Set<String>,
        allowLegacy: Bool
    ) {
        let supported = supportedAlgorithms(session: session, method: method)
        guard !supported.isEmpty else { return }

        // libssh2 returns the list in its own preference order; keep that order
        // and only move the legacy entries to the back, or drop them entirely.
        let modern = supported.filter { !legacy.contains($0) }
        let deprecated = supported.filter { legacy.contains($0) }
        let preference = allowLegacy ? modern + deprecated : modern

        // Never propose an empty list: that would fail the handshake outright.
        // If hardening would leave nothing, fall back to whatever libssh2 has.
        guard !preference.isEmpty else { return }

        _ = preference.joined(separator: ",").withCString {
            libssh2_session_method_pref(session, method, $0)
        }
    }

    /// Algorithm names this build of libssh2 actually supports, in its own
    /// preference order.
    static func supportedAlgorithms(session: OpaquePointer, method: Int32) -> [String] {
        var list: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        let count = libssh2_session_supported_algs(session, method, &list)
        guard count > 0, let list else { return [] }

        defer { libssh2_free(session, UnsafeMutableRawPointer(list)) }

        return (0..<Int(count)).compactMap { index in
            list[index].map { String(cString: $0) }
        }
    }
}
