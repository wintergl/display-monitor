# Contributing

Thanks for helping improve Display Monitor. Small, focused changes are easiest to review.

## Report a problem

Use the issue template and include the app build, macOS version, hardware family, affected feature, and exact reproduction steps. For menu bar problems, say whether the app is in `/Applications` and which permissions are enabled. Use synthetic content when demonstrating screenshots or recording.

Do not attach message databases, credentials, full desktop backups, device serials, or unreviewed screen captures. Report security-sensitive problems through [private vulnerability reporting](https://github.com/wintergl/display-monitor/security/advisories/new).

## Send a change

1. Fork the repo and work on a focused branch.
2. Follow the existing AppKit/SwiftUI and core-policy separation.
3. Run `swift test` and `./script/build_and_run.sh --release-build-only`.
4. Explain the user-visible change, checks you ran, and any native behavior not tested.

Menu bar automation must be cancellable and release input resources. Do not add forced process termination, silent permission bypasses, or production telemetry. Keep personal machine details out of fixtures. English localization and compatibility reports are especially welcome.

Contributions are made under this repository's MIT license. Reuse of third-party code must preserve its license and attribution.
