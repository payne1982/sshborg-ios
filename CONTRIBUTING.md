# Contributing

SSHBorg is a personal project, but bug reports and contributions are welcome.

## Reporting bugs

Open an issue on [GitHub](https://github.com/payne1982/sshborg-ios/issues). Please include:

- iOS version and device model
- SSHBorg version (visible in the app settings)
- Steps to reproduce
- What you expected vs. what happened

If the problem also happens in the Android app, it probably belongs in the
[Android repository](https://github.com/payne1982/sshborg/issues) instead.

## Pull requests

1. Fork the repo and branch off `V1_DEV`
2. Keep changes focused — one fix or feature per PR
3. Target `V1_DEV` (not `V1`, which is the release branch)

## Guidelines

- No ads, analytics, or telemetry — PRs adding any form of tracking will not be accepted
- No proprietary or third-party SDKs — dependencies must be open source and permissively licensed, so that the [licence exception](LICENSE-EXCEPTION) for application stores stays possible
- Translations are maintained in the [Android repository](https://github.com/payne1982/sshborg) and imported from there — please don't edit the String Catalog by hand
- Please write in English for issues and PR descriptions

## Building

See [README.md](README.md) for build instructions.
