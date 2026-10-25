// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OpenSSL

/// AES-128-OCB, the cipher every datagram of mosh's State Synchronisation
/// Protocol is sealed with — OCB version 3, which is RFC 7253.
///
/// This is the one primitive the protocol needs and the platform does not give
/// us: CryptoKit has AES-GCM and no OCB, and Android's implementation leans on
/// BouncyCastle, which has no equivalent here. OpenSSL does have it, it is
/// already in our dependency graph for ``SSHSigner``'s bignums, and the cipher
/// is genuinely in the binary we link rather than only in its header — `nm`
/// reports `_EVP_aes_128_ocb` as a defined symbol in the simulator slice of
/// `openssl-spm`'s xcframework, and ``MoshPrimitiveTests`` says the same thing
/// from inside the app by reproducing the RFC's own vectors.
///
/// **What this deliberately is not.** There is no nonce here, no sequence
/// number, no replay filter and no direction bit: those are the layer above,
/// which mosh calls the packet and Android calls `MoshCrypto`, and they are the
/// part that must never be got wrong twice the same way. This type does one
/// thing, takes the nonce it is given, and has no state at all — so the
/// invariant that matters, *a nonce is never used twice with one key*, is owned
/// by whoever holds the counter and cannot be accidentally satisfied here.
enum MoshOCB {

    /// Mosh uses a 128-bit tag, which is also this cipher's default in OpenSSL,
    /// so the tag length is never set explicitly.
    static let tagLength = 16

    /// 96 bits, the default for OCB-AES in OpenSSL and what mosh's nonce is.
    static let nonceLength = 12

    enum Failure: Error, Equatable {
        /// This OpenSSL was built without OCB. It would be a build change, not
        /// a runtime condition, which is why it is worth saying by name.
        case cipherUnavailable
        case contextUnavailable
        /// The step of the EVP sequence that refused, for a report nobody has
        /// to guess at.
        case openSSL(String)
        case tooShort
    }

    /// Seals `plaintext`, returning the ciphertext with the tag appended, which
    /// is how RFC 7253 and mosh both assemble it.
    ///
    /// `aad` is authenticated and not encrypted: in mosh that is where the
    /// sequence number travels, so a datagram whose number has been edited does
    /// not open.
    static func seal(plaintext: Data, aad: Data, key: Data, nonce: Data) throws -> Data {
        guard let cipher = EVP_aes_128_ocb() else { throw Failure.cipherUnavailable }
        guard let ctx = EVP_CIPHER_CTX_new() else { throw Failure.contextUnavailable }
        defer { EVP_CIPHER_CTX_free(ctx) }

        guard EVP_EncryptInit_ex(ctx, cipher, nil, nil, nil) == 1 else {
            throw Failure.openSSL("EVP_EncryptInit_ex")
        }
        // Before the key, and not after: for OCB this is refused once there is
        // an IV, which is the one ordering rule in the whole sequence.
        guard EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, Int32(nonce.count), nil) == 1 else {
            throw Failure.openSSL("EVP_CTRL_AEAD_SET_IVLEN")
        }
        guard withBytes(key, nonce, { EVP_EncryptInit_ex(ctx, nil, nil, $0, $1) }) == 1 else {
            throw Failure.openSSL("EVP_EncryptInit_ex(key)")
        }

        var moved: Int32 = 0
        if !aad.isEmpty {
            guard withBytes(aad, { EVP_EncryptUpdate(ctx, nil, &moved, $0, Int32(aad.count)) }) == 1
            else { throw Failure.openSSL("EVP_EncryptUpdate(aad)") }
        }

        var body = [UInt8](repeating: 0, count: plaintext.count + 16)
        var produced = 0
        if !plaintext.isEmpty {
            guard withBytes(plaintext, {
                EVP_EncryptUpdate(ctx, &body, &moved, $0, Int32(plaintext.count))
            }) == 1 else { throw Failure.openSSL("EVP_EncryptUpdate") }
            produced = Int(moved)
        }

        // OCB processes whole blocks, so a final partial block is buffered by
        // `Update` and comes out here. It pads nothing; both outputs are real.
        var tail = [UInt8](repeating: 0, count: 32)
        guard EVP_EncryptFinal_ex(ctx, &tail, &moved) == 1 else {
            throw Failure.openSSL("EVP_EncryptFinal_ex")
        }
        let trailing = Int(moved)

        var tag = [UInt8](repeating: 0, count: tagLength)
        guard EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, Int32(tagLength), &tag) == 1 else {
            throw Failure.openSSL("EVP_CTRL_AEAD_GET_TAG")
        }

        var sealed = Data(body[0..<produced])
        sealed.append(contentsOf: tail[0..<trailing])
        sealed.append(contentsOf: tag)
        return sealed
    }

    /// Opens a sealed datagram, or returns `nil` when the tag does not check
    /// out.
    ///
    /// `nil` rather than a thrown error, because it is not an error: a datagram
    /// that does not authenticate is one we never received, and that is the
    /// only thing a caller may do about it. A throw is reserved for the cases
    /// where the library itself refused.
    static func open(sealed: Data, aad: Data, key: Data, nonce: Data) throws -> Data? {
        guard sealed.count >= tagLength else { throw Failure.tooShort }
        let body = Data(sealed.prefix(sealed.count - tagLength))
        var tag = [UInt8](sealed.suffix(tagLength))

        guard let cipher = EVP_aes_128_ocb() else { throw Failure.cipherUnavailable }
        guard let ctx = EVP_CIPHER_CTX_new() else { throw Failure.contextUnavailable }
        defer { EVP_CIPHER_CTX_free(ctx) }

        guard EVP_DecryptInit_ex(ctx, cipher, nil, nil, nil) == 1 else {
            throw Failure.openSSL("EVP_DecryptInit_ex")
        }
        guard EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, Int32(nonce.count), nil) == 1 else {
            throw Failure.openSSL("EVP_CTRL_AEAD_SET_IVLEN")
        }
        // Also before the key: the expected tag carries its own length, and the
        // length cannot be changed once there is an IV.
        guard EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, Int32(tagLength), &tag) == 1 else {
            throw Failure.openSSL("EVP_CTRL_AEAD_SET_TAG")
        }
        guard withBytes(key, nonce, { EVP_DecryptInit_ex(ctx, nil, nil, $0, $1) }) == 1 else {
            throw Failure.openSSL("EVP_DecryptInit_ex(key)")
        }

        var moved: Int32 = 0
        if !aad.isEmpty {
            guard withBytes(aad, { EVP_DecryptUpdate(ctx, nil, &moved, $0, Int32(aad.count)) }) == 1
            else { throw Failure.openSSL("EVP_DecryptUpdate(aad)") }
        }

        var out = [UInt8](repeating: 0, count: body.count + 16)
        var produced = 0
        if !body.isEmpty {
            guard withBytes(body, {
                EVP_DecryptUpdate(ctx, &out, &moved, $0, Int32(body.count))
            }) == 1 else { throw Failure.openSSL("EVP_DecryptUpdate") }
            produced = Int(moved)
        }

        var tail = [UInt8](repeating: 0, count: 32)
        guard EVP_DecryptFinal_ex(ctx, &tail, &moved) == 1 else { return nil }

        var plaintext = Data(out[0..<produced])
        plaintext.append(contentsOf: tail[0..<Int(moved)])
        return plaintext
    }

    // MARK: - Passing `Data` to C

    /// `Data` has no stable pointer of its own, so every call that takes one
    /// goes through `withUnsafeBytes`. An empty `Data` yields a null base
    /// address, which these two never see: both callers guard on `isEmpty`.
    private static func withBytes<T>(
        _ data: Data, _ body: (UnsafePointer<UInt8>) -> T
    ) -> T {
        data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress!) }
    }

    private static func withBytes<T>(
        _ first: Data, _ second: Data, _ body: (UnsafePointer<UInt8>, UnsafePointer<UInt8>) -> T
    ) -> T {
        first.withUnsafeBytes { a in
            second.withUnsafeBytes { b in
                body(
                    a.bindMemory(to: UInt8.self).baseAddress!,
                    b.bindMemory(to: UInt8.self).baseAddress!
                )
            }
        }
    }
}
