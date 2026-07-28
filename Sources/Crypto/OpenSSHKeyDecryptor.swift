// SPDX-License-Identifier: GPL-3.0-or-later

import CommonCrypto
import Foundation

/// Unlocks the encrypted half of a passphrase-protected `openssh-key-v1` file.
///
/// The key material is encrypted with a key derived by bcrypt_pbkdf, which is
/// taken from libssh2 rather than reimplemented — see the bridging header for
/// why a stock bcrypt would be the wrong answer.
///
/// AES-CTR comes from CommonCrypto because CryptoKit offers only the sealed
/// modes: GCM and ChaChaPoly. Counter mode is what OpenSSH writes, so there is
/// no choice to make here.
enum OpenSSHKeyDecryptor {

    enum DecryptionError: Error, Equatable {
        case unsupportedCipher(String)
        case unsupportedKDF(String)
        case malformedKDFOptions
        case keyDerivationFailed
        case decryptionFailed
    }

    /// A cipher OpenSSH might have used, and the key material it needs.
    private struct Cipher {
        let keySize: Int
        let ivSize: Int
        let blockMode: CCMode

        static func named(_ name: String) -> Cipher? {
            switch name {
            case "aes256-ctr": Cipher(keySize: 32, ivSize: 16, blockMode: CCMode(kCCModeCTR))
            case "aes192-ctr": Cipher(keySize: 24, ivSize: 16, blockMode: CCMode(kCCModeCTR))
            case "aes128-ctr": Cipher(keySize: 16, ivSize: 16, blockMode: CCMode(kCCModeCTR))
            case "aes256-cbc": Cipher(keySize: 32, ivSize: 16, blockMode: CCMode(kCCModeCBC))
            case "aes128-cbc": Cipher(keySize: 16, ivSize: 16, blockMode: CCMode(kCCModeCBC))
            default: nil
            }
        }
    }

    /// Decrypts the private section.
    ///
    /// - Parameters:
    ///   - section: the encrypted blob from the key file.
    ///   - cipherName: the file's `ciphername` field.
    ///   - kdfName: the file's `kdfname` field, which must be `bcrypt`.
    ///   - kdfOptions: the file's `kdfoptions`, a salt string and a round count.
    static func decrypt(
        section: Data,
        cipherName: String,
        kdfName: String,
        kdfOptions: Data,
        passphrase: String
    ) throws -> Data {
        guard let cipher = Cipher.named(cipherName) else {
            throw DecryptionError.unsupportedCipher(cipherName)
        }
        guard kdfName == "bcrypt" else {
            throw DecryptionError.unsupportedKDF(kdfName)
        }

        var options = SSHWireDecoder(kdfOptions)
        guard let salt = try? options.readString(),
              let rounds = try? options.readUInt32(),
              !salt.isEmpty, rounds > 0
        else {
            throw DecryptionError.malformedKDFOptions
        }

        // One derivation produces the key and the IV back to back, which is how
        // OpenSSH splits it.
        let material = try deriveKey(
            passphrase: passphrase,
            salt: salt,
            rounds: rounds,
            length: cipher.keySize + cipher.ivSize
        )

        return try transform(
            section,
            key: material.prefix(cipher.keySize),
            iv: material.suffix(cipher.ivSize),
            mode: cipher.blockMode
        )
    }

    // MARK: - Key derivation

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        rounds: UInt32,
        length: Int
    ) throws -> Data {
        var output = [UInt8](repeating: 0, count: length)
        let passphraseBytes = Array(passphrase.utf8)
        let saltBytes = Array(salt)

        let result = passphraseBytes.withUnsafeBufferPointer { pass in
            saltBytes.withUnsafeBufferPointer { saltPointer in
                pass.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pass.count) { passChars in
                    _libssh2_bcrypt_pbkdf(
                        passChars,
                        pass.count,
                        saltPointer.baseAddress,
                        saltPointer.count,
                        &output,
                        output.count,
                        rounds
                    )
                }
            }
        }

        guard result == 0 else { throw DecryptionError.keyDerivationFailed }
        return Data(output)
    }

    // MARK: - Decryption

    private static func transform(_ data: Data, key: Data, iv: Data, mode: CCMode) throws -> Data {
        var cryptorOrNil: CCCryptorRef?

        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    mode,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress, key.count,
                    nil, 0, 0,
                    // Counter mode has to be told the counter is big-endian.
                    // It is ignored for CBC.
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptorOrNil
                )
            }
        }

        guard createStatus == kCCSuccess, let cryptor = cryptorOrNil else {
            throw DecryptionError.decryptionFailed
        }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: data.count)
        var written = 0

        let updateStatus = data.withUnsafeBytes { input in
            CCCryptorUpdate(
                cryptor,
                input.baseAddress, data.count,
                &output, output.count,
                &written
            )
        }

        guard updateStatus == kCCSuccess else { throw DecryptionError.decryptionFailed }
        return Data(output.prefix(written))
    }
}
