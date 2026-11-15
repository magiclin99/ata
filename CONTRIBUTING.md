# Contributing to ATA

Thanks for helping. Bug reports, fixes, translations and protocol reviews are all welcome. For anything larger than
a small fix, please open an issue first so we can agree on the approach before you spend time on it.

Security problems: please follow [`SECURITY.md`](SECURITY.md) instead of opening a public issue.

## Build and test from a clean clone

Clone the whole repository. Both apps' tests read the shared protocol vectors in `spec/vectors.json` from the root.
**You don't need the developer's signing keys or any other secret.** Development builds are ad-hoc signed (Mac) or
debug-signed (Android).

```sh
git clone https://github.com/magiclin99/ata.git
cd ata
```

### Mac (`mac-app/`)

Needs macOS 14 or later and Xcode 16 (Swift 6 toolchain). SwiftPM downloads the WebRTC xcframework on the first
build.

```sh
cd mac-app
swift test                      # unit, engine and loopback tests (one live test is skipped unless configured)
scripts/build-app.sh            # debug app with the SPEC §9 hooks → build/ATA.app (ad-hoc signed)
scripts/build-app.sh release    # release configuration, hooks compiled out → build/ATA.app (ad-hoc signed)
```

An ad-hoc build looks like a new app to macOS every time, so expect the Bluetooth prompt after each rebuild. Quit
any installed ATA first: only one copy runs at a time. More in [`mac-app/README.md`](mac-app/README.md), including
the fake phone (`ata-fakephone`) for testing without a real device.

### Android (`android-app/`)

Needs JDK 17 or newer and the Android SDK (platform 36, build-tools 36.0.0). Tell Gradle where the SDK is, either
with `ANDROID_HOME` or with an `android-app/local.properties` file (it's ignored by git):

```sh
cd android-app
echo "sdk.dir=/path/to/Android/sdk" > local.properties    # or: export ANDROID_HOME=/path/to/Android/sdk
export JAVA_HOME=/path/to/jdk                             # if `java -version` isn't 17+
./gradlew :core:test assembleDebug     # protocol tests + app/build/outputs/apk/debug/app-debug.apk
./gradlew lintDebug                    # optional
```

`core/` is plain Kotlin/JVM, so most protocol work can be tested without a phone. A real phone (Android 9 or later)
with Bluetooth LE is needed for end-to-end tests. `./gradlew bundleRelease` works without keys too and produces an
unsigned bundle. More in [`android-app/README.md`](android-app/README.md).

### CI

Pull requests run [Android CI](.github/workflows/android-ci.yml) (`:core:test` and `assembleDebug`). Please run
`swift test` locally for Mac changes, because the Mac tests run in CI only for release tags.

## Protocol changes

[`SPEC.md`](SPEC.md) (Traditional Chinese) is the contract between the two apps. A change to anything on the wire
(messages, framing, crypto, pairing URI, limits) must, in the same pull request:

1. update `SPEC.md`,
2. update `spec/vectors.json` if any fixed input or output changes, and
3. keep both apps' vector tests passing (`swift test` in `mac-app/`, `./gradlew :core:test` in `android-app/`).

Both apps implement the same version, so a protocol change usually touches both. If you can only do one side, say
so in the pull request.

## Code and commits

- Match the style of the file you're editing. Kotlin follows the official Kotlin style, Swift the usual Swift API
  guidelines. Keep the protocol core (`android-app/core/`, `mac-app/Sources/ATACore/`) free of UI code.
- Add or update tests for behaviour changes. Don't weaken existing security checks or the "never log keys" tests.
- Never log or commit pairing links, keys, QR codes, real device names, or files from your own devices. Use made-up
  values in tests (the existing tests show the pattern).
- No analytics, ads, trackers, crash reporters, or SDKs that contact a server. "No server, no data collected" is a
  promise both apps make.
- User-facing text exists in English and Traditional Chinese. If you can't translate, leave the English and say so
  in the pull request.
- Write commit messages in the imperative, with a short summary line (for example `android: retry the BLE scan
  after Bluetooth is turned on`). The prefixes `android:`, `mac:`, `spec:`, `site:` and `ci:` help.
- By contributing you agree that your contribution is released under the project's [MIT License](LICENSE).
