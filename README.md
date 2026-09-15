# SSHBorg for iOS

An SSH client for iPhone and iPad. Full terminal emulation, SFTP file manager, SSH key management, jump hosts, agent and port forwarding, and Face ID lock — with no ads, no tracking, and no cloud.

The iOS counterpart of [SSHBorg for Android](https://github.com/payne1982/sshborg): same features, same ten languages, and backups that move between the two. Available on the App Store.

[![Website](https://img.shields.io/badge/website-sshborg.com-222222?style=for-the-badge)](https://sshborg.com/)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE) &nbsp; [![Leave a tip on Ko-fi](https://img.shields.io/badge/Ko--fi-tip-FF5E5B?style=flat&logo=ko-fi&logoColor=white)](https://ko-fi.com/massimilianoplaydev)

## Features

- **SSH terminal** — xterm emulation, full UTF-8, multiple sessions in tabs, pinch to zoom, a customisable extra key bar, and command suggestions from the server's shell history
- **SFTP file manager** — browse, upload, download, rename, and delete files
- **SSH keys** — generate Ed25519, ECDSA, and RSA keys on the device, or import your own
- **Jump hosts** — connect through one or more bastion hosts
- **Agent and port forwarding** — forward your keys through jump chains, and local ports to the server
- **Host groups** — organise hosts in groups, in the order you choose
- **App lock** — Face ID, Touch ID or the device passcode
- **Encrypted at rest** — passwords and private keys protected by the device Keychain
- **Backup / restore** — hosts and settings as JSON, compatible with the Android app (credentials excluded)
- **Ten languages** — English, Italian, German, Spanish, French, Portuguese, Ukrainian, Russian, Chinese and Japanese
- **No ads, no tracking, no third-party SDKs**

Requires iOS 16 or later, on iPhone and iPad.

## How it relates to the Android app

This is not a shared codebase: it is a native rewrite in Swift and SwiftUI. What
carries over is the design — the data model, the feature set and the wording —
so the two apps behave the same way and say the same things.

The translations are maintained once, in the Android repository.
`scripts/import-android-strings.py` reads its resources and produces the iOS
String Catalog, keeping the Android keys verbatim so a sync is a re-run rather
than a merge.

Where the platforms force a difference — iOS suspends apps in the background,
for instance, so connections are re-established when you come back — the
[user guide](https://sshborg.com/docs.html) says so.

## Building

The Xcode project is **not** committed — it is generated from [`project.yml`](project.yml)
by [XcodeGen](https://github.com/yonaskolb/XcodeGen). This keeps the project
text-based, reviewable, and free of `.pbxproj` merge conflicts.

```bash
git clone https://github.com/payne1982/sshborg-ios.git
cd sshborg-ios

brew install xcodegen
xcodegen generate
open SSHBorg.xcodeproj
```

The first build compiles libssh2 and OpenSSL from source and takes a while.
With Xcode 26, SwiftTerm's Metal shaders also need the Metal toolchain, a
separate component: `xcodebuild -downloadComponent MetalToolchain`.

To run on a physical device, add your Team ID:

```bash
cp Configs/Local.xcconfig.example Configs/Local.xcconfig
# edit it, then regenerate:
xcodegen generate
```

`Configs/Local.xcconfig` is git-ignored. Building for the simulator needs no signing.

## Tests

```bash
xcodebuild test -project SSHBorg.xcodeproj -scheme SSHBorg \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  CODE_SIGNING_ALLOWED=NO -skipMacroValidation
```

Use any simulator you have installed. `-skipMacroValidation` because Perception
ships a Swift macro, and Xcode refuses to run an unapproved macro plugin from
the command line — the approval it wants is a click in the GUI.

The SSH and SFTP integration suites skip themselves unless pointed at a real
server, which keeps a plain checkout green:

```bash
SSHBORG_TEST_HOST=… SSHBORG_TEST_USER=… SSHBORG_TEST_PASSWORD_B64=…
```

Base64 for the password because Xcode evaluates build-setting values, and a `$`
in a password is read as a reference to another setting.

## Layout

```
Sources/
  App/          entry point, root view, launch-time notices, shared views
  Data/         GRDB schema, repositories, preferences
  Platform/     Keychain, biometrics, app lock, jailbreak detection
  SSH/          libssh2 wrapper, sessions, SFTP, forwarding
  Terminal/     SwiftTerm integration
  Features/     one directory per screen
  Resources/    assets, string catalog, privacy manifest
Tests/          unit tests, plus UI tests that attach screenshots
Tools/          build and porting scripts
scripts/        source checks and the Android string importer
```

## Dependencies

- [libssh2](https://libssh2.org) via [libssh2-spm](https://github.com/Lakr233/libssh2-spm), with OpenSSL — SSH protocol implementation. Chosen over the pure-Swift libraries, which do not support RSA.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulator
- [GRDB](https://github.com/groue/GRDB.swift) — local database, with the same schema as the Android app
- [Perception](https://github.com/pointfreeco/swift-perception) — Swift Observation on iOS 16, which is why view bodies are wrapped in `WithPerceptionTracking`
- SwiftUI, with UIKit where needed — UI framework
- CryptoKit and the Keychain — encryption at rest, in the same format as the Android app so backups stay interoperable

## Export compliance

SSHBorg uses cryptography — the SSH protocol through libssh2 and OpenSSL, and
AES-GCM from CryptoKit for keys and passwords stored on the device — but only
standard algorithms, and nothing proprietary.

`ITSAppUsesNonExemptEncryption` is `false` in `project.yml`. Apple's definition
of that key is about **documentation to upload to App Store Connect**, not
about whether an app encrypts: `NO` when the app only uses encryption that is
exempt from those documentation requirements. For standard algorithms the only
document Apple asks for is the French encryption declaration, and only for
distribution in France. The App Store Connect questionnaire, answered with
standard algorithms and no distribution in France, concluded that no
documents are needed.

Two things follow:

- **France stays out of the App Store availability** until an ANSSI
  declaration exists. Adding it without one would make that answer false.
- On the US side, encryption source code that is publicly available and uses
  only standard cryptography is not subject to the EAR (15 CFR 742.15(b)); no
  notification is needed for standard cryptography. That relies on this
  repository being public.

`true` is not a safe default either: without an
`ITSEncryptionExportComplianceCode`, which Apple issues only after approving
uploaded documentation, the upload is rejected with ITMS-90592.

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

SSHBorg is free software: you can redistribute it and/or modify it under the
terms of the [GNU General Public License v3.0 or later](LICENSE), the same
licence as the Android app.

The GPL and the terms of an application store are in tension: the GPL forbids
imposing further restrictions, and those services impose some — device limits
and digital restrictions on the delivered binary. Projects have lost their
listings over exactly this.

[LICENSE-EXCEPTION](LICENSE-EXCEPTION) resolves it, as section 7 of the GPL
provides for: an additional permission allowing distribution through such a
service, and nothing more. It takes no right away from you — a copy from an
application store carries the same rights as a copy from this repository.

The permission can be granted because every dependency is permissively
licensed — SwiftTerm and GRDB under MIT, libssh2 under BSD-3-Clause, OpenSSL
3.x under Apache-2.0 — so the GPL-covered work has a single copyright holder.
