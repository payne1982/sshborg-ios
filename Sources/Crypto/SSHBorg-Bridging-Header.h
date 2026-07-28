// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef SSHBORG_BRIDGING_HEADER_H
#define SSHBORG_BRIDGING_HEADER_H

#include <stddef.h>
#include <stdint.h>

// Declared here because libssh2 keeps it in src/libssh2_priv.h, which is not on
// the public include path — but the symbol is compiled into the library we
// already link, so it resolves.
//
// This is deliberately not reimplemented and deliberately not taken from a
// general-purpose bcrypt package. OpenSSH's KDF uses a *modified* Blowfish
// (bcrypt_hash with its own round structure), so a stock bcrypt derives a
// different key and the file simply will not open. What libssh2 ships is the
// OpenBSD source that OpenSSH itself uses.
//
// The risk accepted: a private symbol could be renamed upstream. The version is
// pinned to libssh2 1.11.1 and a rename would fail the link immediately, and
// there is a test that decrypts a real ssh-keygen key to catch a behavioural
// change.
int _libssh2_bcrypt_pbkdf(const char *pass,
                          size_t passlen,
                          const uint8_t *salt,
                          size_t saltlen,
                          uint8_t *key,
                          size_t keylen,
                          unsigned int rounds);

#endif /* SSHBORG_BRIDGING_HEADER_H */
