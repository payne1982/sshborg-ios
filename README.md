# SSHBorg for iOS

An iOS port of [SSHBorg](https://github.com/payne1982/sshborg), the ad-free, tracking-free SSH client for Android.

> **Status: phase 0 — foundations.** Nothing works yet. The app currently builds
> to a single screen that verifies the dependency stack links and runs on device.
> See [PIANO.md](PIANO.md) for the full roadmap (in Italian).

The Android app is not a shared codebase — this is an independent native rewrite
in Swift/SwiftUI. Roughly 7% of the Android source is directly translatable (the
terminal emulator core); the rest is platform-bound. What carries over is the
design: the data model, the feature set, and 287 strings across 10 languages,
all validated in production.

## Stack

| Concern | Choice | Why |
|---|---|---|
| SSH transport | [libssh2](https://libssh2.org) via [libssh2-spm](https://github.com/Lakr233/libssh2-spm) (`CSSH2`) | swift-nio-ssh and Citadel are pure Swift but support **no RSA** — disqualifying for a general-purpose client. libssh2 is what Blink Shell and Secure ShellFish ship. |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Mature, MIT, commercially proven. Solves iOS IME, selection loupe and accessibility, which are the genuinely hard parts. |
| Database | [GRDB](https://github.com/groue/GRDB.swift) | Explicit control over the schema and migrations, mirroring the Android Room schema. |
| Secrets | Keychain + Secure Enclave | Same AES-256-GCM blob format as the Android Keystore, so backups stay interoperable. |
| UI | SwiftUI (UIKit where needed) | |

Minimum iOS 17.0, universal iPhone/iPad.

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

To run on a physical device, add your Team ID:

```bash
cp Configs/Local.xcconfig.example Configs/Local.xcconfig
# edit it, then regenerate:
xcodegen generate
```

`Configs/Local.xcconfig` is git-ignored. Building for the simulator needs no signing.

## Layout

```
Sources/
  App/          entry point, root view
  Data/         GRDB schema, repositories, preferences      (phase 1)
  Platform/     Keychain, biometrics, jailbreak detection   (phase 1)
  SSH/          libssh2 wrapper, sessions, SFTP             (phases 2, 6, 7)
  Terminal/     SwiftTerm integration                       (phase 3)
  Features/     one directory per screen
  Resources/    assets, privacy manifest
Tests/
Tools/          build and porting scripts
```

## Export compliance

`ITSAppUsesNonExemptEncryption` is currently set to `true` in `project.yml`. The
app embeds OpenSSL and performs general-purpose cryptography, so this is the
conservative reading. **This must be confirmed before the first App Store
submission** — the answer determines whether a self-classification report is
required.

## License

Mozilla Public License 2.0 — see [LICENSE](LICENSE).

Note that the Android app is GPLv3. The two codebases are independent, and the
iOS port is deliberately licensed differently: the GPL forbids imposing further
restrictions, while the App Store terms impose them, and that conflict has cost
projects their listings before. MPL-2.0 is file-level copyleft with no such
friction — it is the license Firefox for iOS ships under.
