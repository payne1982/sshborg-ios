# SSHBorg for iOS

An iOS port of [SSHBorg](https://github.com/payne1982/sshborg), the ad-free, tracking-free SSH client for Android.

> **Status: feature-complete against the Android app, not yet released.**
> Terminal, SFTP, key management, jump hosts, agent forwarding, port forwarding,
> host groups, cross-platform backup, app lock and ten languages all work. 281
> unit tests and 5 UI tests pass on the simulator.
>
> Two things have never run on physical hardware, and both are named here rather
> than left to be discovered: **at-rest encryption through the Keychain**, which
> an unsigned build cannot reach at all (every call returns
> `errSecMissingEntitlement`), and the **app lock** against real biometrics.
> Neither is a known defect — they are parts that have not yet been observed.

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
| Observation | [Perception](https://github.com/pointfreeco/swift-perception) | `@Observable` is iOS 17 and the floor is 16. Back-ports Observation rather than going back to `ObservableObject`, which does not track reads through nested objects and would have failed silently. |
| UI | SwiftUI (UIKit where needed) | |

Minimum iOS 16.0, universal iPhone/iPad. The floor is 16 rather than 17 so that
the A11 devices — iPhone 8, 8 Plus and X, which stop at iOS 16.7.x — are not
excluded. `@Observable` was the only API keeping it at 17; it is supplied on 16
by [Perception](https://github.com/pointfreeco/swift-perception), which is why
view bodies here are wrapped in `WithPerceptionTracking`.

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
  App/          entry point, root view, launch-time notices, shared views
  Data/         GRDB schema, repositories, preferences
  Platform/     Keychain, biometrics, app lock, jailbreak detection
  SSH/          libssh2 wrapper, sessions, SFTP
  Terminal/     SwiftTerm integration
  Features/     one directory per screen
  Resources/    assets, string catalog, privacy manifest
Tests/          unit tests, plus UI tests that attach screenshots
Tools/          build and porting scripts
scripts/        source checks and the Android string importer
```

The strings are not translated here. `scripts/import-android-strings.py` reads
the Android app's resources and produces the iOS String Catalog, keeping the
Android keys verbatim so a future sync is a re-run rather than a merge — the two
apps say the same things in the same ten languages, and the wording is
maintained in one place.

## Tests

```bash
xcodebuild test -project SSHBorg.xcodeproj -scheme SSHBorg \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  CODE_SIGNING_ALLOWED=NO -skipMacroValidation
```

`-skipMacroValidation` because Perception ships a Swift macro, and Xcode refuses
to run an unapproved macro plugin from the command line — the approval it wants
is a click in the GUI.

The SSH and SFTP integration suites skip themselves unless pointed at a real
server, which keeps a plain checkout green:

```bash
SSHBORG_TEST_HOST=… SSHBORG_TEST_USER=… SSHBORG_TEST_PASSWORD_B64=…
```

Base64 for the password because Xcode evaluates build-setting values, and a `$`
in a password is read as a reference to another setting.

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

## License

GNU General Public License v3.0 or later — see [LICENSE](LICENSE), the same
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
