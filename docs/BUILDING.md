# Build Display Monitor

## Requirements

- macOS on Apple Silicon for the initial supported development path.
- Xcode 26+ with the macOS 26 SDK or newer, and Swift 6. The initial public source was verified with Swift 6.4 on macOS 27.0.1.
- The macOS Command Line Tools selected with `xcode-select`.

The package has no external package dependencies. `Package.swift` declares macOS 13 as the deployment target, but compiling the newest capture paths requires a recent SDK. The declaration is not a claim that every feature has been tested on every macOS release. Intel and older OS versions need additional native acceptance testing.

## Build and launch

```sh
./script/build_and_run.sh --release-build-only
# Output: dist/Display Monitor.app
./script/build_and_run.sh --run-dev
# Or build debug without launching:
./script/build_and_run.sh --build-only
```

No command force-quits another copy or installs into `/Applications`. `--run-dev` refuses to open a second running instance. The script also refuses to overwrite its staged app while that staged app is running. Quit through the app menu first.

Menu bar hiding intentionally requires an app in `/Applications`. To test it, quit other copies, preserve any installed version you need, and manually install your built app. The app uses the original bundle identifier so source builds and the published app share a macOS identity: changing signatures may require reauthorizing permissions. Keep a backup before replacing an installed version. Development-path launches can still exercise other tools.

## Signing

By default the script uses ad hoc signing (`codesign --sign -`). No author certificate, Apple ID, or Team ID is required. For a certificate you own:

```sh
DISPLAY_MONITOR_SIGN_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)' \
  ./script/build_and_run.sh --release-build-only
```

A Developer ID build receives hardened runtime and a timestamp. Signing alone does not notarize it. To distribute your own build, submit it with your own Apple credentials using Apple's notarization tools; never commit certificates, passwords, or keychain exports. Ad hoc builds are intended for local development and have no Developer ID notarization.

The `script/` folder in this public repository is a portable build entry point. It intentionally does not include private maintenance, installation, or desktop-acceptance scripts.

## Tests

```sh
swift test
```

The ordinary suite covers policies, rendering, coordination, and cancellation with synthetic fixtures and fakes. Long-image stress acceptance requires an explicit opt-in fixture and is skipped by default. It does not run live menu bar drags or native permission acceptance. Real screenshot capture, recording, display control, and menu bar behavior need separate interactive testing.

## Release provenance

The initial `v0.1.1` release includes the existing Developer ID signed and notarized Apple Silicon build **59**. Its signature is preserved. The public source snapshot removes private signing defaults and supplies a portable build script and public documentation. It is not a claim of a byte-for-byte reproducible build of the existing binary. The release assets provide SHA-256 checksums for integrity verification.
