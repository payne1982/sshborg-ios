// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// Chooses which key exchange, host key and cipher algorithms to offer.
///
/// The algorithm names are never hard-coded as a whole list: they are read back
/// from libssh2 with `libssh2_session_supported_algs`, then split into what is
/// offered by default, what only the "legacy ciphers" option adds, and what is
/// never offered. That way every name handed to `libssh2_session_method_pref`
/// is guaranteed to exist in this build.
///
/// The result matches the Android app exactly, where JSch's default lists
/// already leave these algorithms out and `applyLegacyCiphers` appends a fixed
/// set back. Until 13/09/2026 this file said it matched and did not: the legacy
/// option also enabled `ssh-rsa` host keys and three ciphers Android never
/// offers, and two algorithms slipped past the filter to be offered by default.
/// The website's guide describes one list for both apps, and now it is true.
enum SSHAlgorithms {

    /// CBC ciphers and 3DES, added only for hosts with the legacy option on.
    /// The same four as Android's `applyLegacyCiphers`.
    static let legacyCiphers: Set<String> = [
        "aes128-cbc",
        "aes192-cbc",
        "aes256-cbc",
        "3des-cbc",
    ]

    /// SHA-1 key exchanges, added only with the legacy option on.
    static let legacyKeyExchanges: Set<String> = [
        "diffie-hellman-group14-sha1",
        "diffie-hellman-group-exchange-sha1",
        "diffie-hellman-group1-sha1",
    ]

    /// DSA host keys, added only with the legacy option on.
    ///
    /// Kept for parity, but inert in the build this app ships: its OpenSSL
    /// leaves DSA out, libssh2 then reports no `ssh-dss`, and a DSA-only server
    /// cannot be reached from iOS at all. `SSHAlgorithmsTests` pins that, and the
    /// website's guide tells iOS users.
    static let legacyHostKeys: Set<String> = [
        "ssh-dss",
    ]

    /// Algorithms libssh2 knows and this app never offers, legacy option or not.
    ///
    /// None of them is in JSch's lists, so offering them would make a host
    /// reachable from one app and not from the other.
    ///
    /// - The ciphers are also unlikely to work at all here: libssh2 lists them
    ///   because OpenSSL was built with them, but OpenSSL 3 keeps Blowfish, CAST
    ///   and RC4 in its legacy provider, which nothing loads, so a server that
    ///   picked one would fail the handshake.
    /// - `rijndael-cbc@lysator.liu.se` is aes256-cbc under an old name, and was
    ///   offered by default because it was in neither list.
    /// - `ssh-rsa` host keys are RSA signed with SHA-1; the SHA-2 forms
    ///   (`rsa-sha2-256`, `rsa-sha2-512`) are what modern servers use, and JSch
    ///   offers only those. The certificate form was offered by default too.
    static let neverOffered: Set<String> = [
        "blowfish-cbc",
        "cast128-cbc",
        "arcfour",
        "arcfour128",
        "arcfour256",
        "rijndael-cbc@lysator.liu.se",
        "ssh-rsa",
        "ssh-rsa-cert-v01@openssh.com",
    ]

    /// Applies the preference lists to a session. Must be called *before* the
    /// handshake, which is when libssh2 sends its algorithm proposal.
    static func applyPreferences(to session: OpaquePointer, allowLegacy: Bool) {
        apply(to: session, method: LIBSSH2_METHOD_KEX, legacy: legacyKeyExchanges, allowLegacy: allowLegacy)
        apply(to: session, method: LIBSSH2_METHOD_HOSTKEY, legacy: legacyHostKeys, allowLegacy: allowLegacy)
        apply(to: session, method: LIBSSH2_METHOD_CRYPT_CS, legacy: legacyCiphers, allowLegacy: allowLegacy)
        apply(to: session, method: LIBSSH2_METHOD_CRYPT_SC, legacy: legacyCiphers, allowLegacy: allowLegacy)
    }

    /// What to propose, given what libssh2 supports.
    ///
    /// libssh2 returns its list in its own preference order; that order is kept,
    /// the legacy entries go to the back when allowed, and the never-offered ones
    /// are dropped either way.
    static func preference(supported: [String], legacy: Set<String>, allowLegacy: Bool) -> [String] {
        let usable = supported.filter { !neverOffered.contains($0) }
        let modern = usable.filter { !legacy.contains($0) }
        let deprecated = usable.filter { legacy.contains($0) }
        return allowLegacy ? modern + deprecated : modern
    }

    private static func apply(
        to session: OpaquePointer,
        method: Int32,
        legacy: Set<String>,
        allowLegacy: Bool
    ) {
        let supported = supportedAlgorithms(session: session, method: method)
        guard !supported.isEmpty else { return }

        let preference = preference(supported: supported, legacy: legacy, allowLegacy: allowLegacy)

        // Never propose an empty list: that would fail the handshake outright.
        // It cannot happen with the libssh2 this app ships, which always has
        // modern algorithms for every method.
        guard !preference.isEmpty else { return }

        _ = preference.joined(separator: ",").withCString {
            libssh2_session_method_pref(session, method, $0)
        }
    }

    enum Method {
        case keyExchange, hostKey, cipher

        fileprivate var libssh2Method: Int32 {
            switch self {
            case .keyExchange: LIBSSH2_METHOD_KEX
            case .hostKey: LIBSSH2_METHOD_HOSTKEY
            case .cipher: LIBSSH2_METHOD_CRYPT_CS
            }
        }
    }

    /// What this build of libssh2 supports, read from a session that never
    /// connects. For the tests, which cannot see libssh2's constants, and for
    /// checking that the names in the lists above are the library's own.
    static func supportedByThisBuild(_ method: Method) -> [String] {
        guard libssh2_init(0) == 0 else { return [] }
        defer { libssh2_exit() }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { return [] }
        defer { libssh2_session_free(session) }
        return supportedAlgorithms(session: session, method: method.libssh2Method)
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
