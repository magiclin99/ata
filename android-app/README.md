# ATA for Android (sender, protocol v2)

Shares files from an Android phone to a paired Mac. Contract: [`../SPEC.md`](../SPEC.md) (protocol v2). Free and open
source under the MIT License ([`LICENSE`](LICENSE)); third-party notices are in
`app/src/main/res/raw/third_party_notices.txt` (also shown in the app).
applicationId/namespace `io.github.magiclin99.ata`, versionName 1.0.0 (versionCode 1), minSdk 28, targetSdk 36.
The protocol core keeps its own package `com.ata.core`.

## Layout

| Module | What |
|---|---|
| `core/` | Pure Kotlin/JVM, no Android: crypto (HMAC, HKDF, AES-GCM counters), pairing URI, BLE fragmentation, JSON messages, handshake, encrypted session, record framing, `TransferEngine` (send → accept → LAN TCP → WebRTC → records → bye). |
| `app/` | Android: BLE central (`BleLink`, scan, probe), LAN dialer bound to the Wi-Fi `Network`, WebRTC (`AndroidRtcPeer`), Keystore-wrapped pairing store, foreground `TransferService` (type connectedDevice), QR scanner (`ScanActivity`, CameraX + ZXing), Compose UI (main screen with about section, send sheet). |
| `app/src/debug/` | Debug-only: SPEC §9 automation hooks (`DebugHooks`). `app/src/release/` holds the no-op `DebugHooks`. |

## Build and test

```sh
export JAVA_HOME=/path/to/jdk   # JDK 17 or newer
./gradlew :core:test         # vectors, framing, pairing URI, fake-Mac loopback (LAN, WebRTC fallback, tamper cases)
./gradlew assembleDebug      # app/build/outputs/apk/debug/app-debug.apk
./gradlew lintDebug          # app/build/reports/lint-results-debug.txt
./gradlew lintRelease
./gradlew bundleRelease      # R8-minified AAB signed with the upload key: app/build/outputs/bundle/release/app-release.aab
```

Layout screenshots (opt-in; Robolectric downloads an Android runtime the first time): the empty screen, pairing and
permission dialogs and the scanner hint at 320, 360 and 411 dp wide and font scale 1.0 and 1.3, in both languages,
saved to `app/build/screenshots/`. Look at them after changing any of that wording.

```sh
./gradlew :app:testDebugUnitTest -Pata.screenshots --tests '*LayoutScreenshotTest*'
```

Needs the Android SDK: set `sdk.dir` in `local.properties` (not committed) or `ANDROID_HOME`. The vector test reads
`../spec/vectors.json` in place, so build from a checkout of the whole repository. A debug build needs no secrets.

### Release signing

`bundleRelease` signs with the upload key described by a properties file outside the repo: Gradle property
`-Pata.signing=<file>`, else env `ATA_SIGNING_PROPERTIES`, else `~/ata-secrets/android/signing.properties`
(keys `storeFile`, `storePassword`, `keyAlias`, `keyPassword`). Without it the AAB is built unsigned, so anyone can
build it. Play App Signing holds the app signing key. Never commit the keystore or that file.

ABIs: arm64-v8a (16 KB-aligned `libjingle_peerconnection_so.so`) and armeabi-v7a; Play serves one per device.
x86/x86_64 are left out (emulators/Chromebooks; the BLE-to-Mac use case is phones).

### Launcher icon

Brand icon (generated from the project's brand kit; treat these files as generated):
`res/drawable/ic_launcher_{foreground,background,monochrome}.xml`, wired by `res/mipmap-anydpi-v26/ic_launcher.xml`
(monochrome = Android 13+ themed icon). `res/drawable/ic_stat_ata.xml` is the same mark as a white 24 dp glyph for
the notification and the sheet title; `res/drawable/ic_mac.xml` is the generic computer glyph on Mac rows.

## Debug automation (SPEC §9, debug builds only)

```sh
ADB=adb   # or the full path to platform-tools/adb
# Grant BLE permissions once so the hooks never stop at a permission dialog (API 31+):
$ADB shell pm grant io.github.magiclin99.ata android.permission.BLUETOOTH_SCAN
$ADB shell pm grant io.github.magiclin99.ata android.permission.BLUETOOTH_CONNECT
$ADB shell pm grant io.github.magiclin99.ata android.permission.POST_NOTIFICATIONS

$ADB shell am start -n io.github.magiclin99.ata/.MainActivity --es debugPairUri "'ata://pair?v=2&id=...&name=...&k=...'"
$ADB shell am start -n io.github.magiclin99.ata/.MainActivity --ei debugSendMiB 50 --ei debugCount 3
$ADB shell am start -n io.github.magiclin99.ata/.MainActivity --ei debugSendMiB 50 --ez debugForceRtc true
$ADB logcat -s ATA
```

Quote the pairing URI for the device shell (`&` is a shell operator). Log lines to watch:

- `PAIR ok=<bool> ...` after a pairing attempt.
- `RESULT ok=<bool> via=<lan|rtc|none> files=<n> bytes=<n> ms=<n>` after every transfer. `files`/`bytes` count only
  files the Mac confirmed with `{"ok":true}`; `ms` is the whole job (file preparation, BLE scan, handshake, transfer).
  A second line `transfer: <ms> ms after authentication` isolates the transfer.

## Share flow (SPEC §3a)

Sharing to "傳到 Mac" always opens a picker of all paired Macs; nothing starts until the user taps a Mac marked
"在附近". Nearness comes from a continuous BLE scan (`NearbyScanner`): the advertised local name `ATA-<8 hex>` is
matched against paired macIds; a record without a usable name is probed once (connect, read `hello.id`, disconnect,
no `auth`). An entry expires 10 s after its last advertisement. With no paired Mac the picker offers pairing inline
and returns to the list with the shared files kept. The tapped Mac's BLE address is handed to `TransferService`,
which connects to it directly and falls back to scanning for that Mac if the address no longer answers.

`debugSendMiB` bypasses the picker and writes `debugCount` random files to the app cache and sends them to the only paired Mac (it fails with
`RESULT ok=false` if zero or several Macs are paired).

## Security notes

- K is encrypted with a non-exportable AES-256-GCM Android Keystore key before it is stored; backups are disabled.
- MACs are compared with `MessageDigest.isEqual` (constant time).
- Logs never contain K, session keys, nonces, HMACs or the pairing URI (the loopback test asserts K never reaches the log).

## User-facing wording

Every string a user sees follows the shared glossary (internal `TERMS.md`): plain words for a non-technical reader,
no connection-path names (the path stays in logs only), no codes or raw system text, and each error says what
happened plus one thing to try (`Texts.kt`, `res/values*/strings.xml`). Specifics:

- A finished transfer reads 「已傳送到你的 Mac「X」」 / "Sent to your Mac "X"". When part of it went over mobile data
  it adds 「（用了約 N 行動數據）」. Measurement: while the WebRTC path is active, `AndroidRtcPeer` marks the selected
  ICE pair as mobile data when the local candidate's adapter type is cellular (or, if unknown, when its local
  address belongs to a cellular `Network`); `TransferService` adds each progress delta to the count while that flag
  is set. The LAN path is bound to Wi-Fi/Ethernet and never counts. It is payload bytes, so the UI says "about".
- Pairing is QR-code only for users. The "paste pairing link" dialog exists only in debug builds (the Mac has no
  way to show the link); `debugPairUri` keeps working.
- Each system permission prompt is preceded by one plain line that names the option to choose as the system dialog
  shows it (camera: 「使用應用程式時」 / "While using the app", since there is no plain "Allow" there) and says the
  wording may differ; a refusal leads to one "Open Settings" button.
- Never hard-code line breaks. In zh-TW strings, words that must not split are joined with U+2060 (`&#8288;`), and
  「QR&#160;code」 uses a no-break space; see the comment at the top of `values/strings.xml`.
- The third-party notices are shown verbatim but reflowed to the screen width (`Notices.kt`; a test checks that no
  word changes), under a one-line introduction in the UI language.

## Free app; reserved donation entry

- ATA is completely free: no in-app purchases, no paywall, no transfer limit, no ads, no analytics. The app does not
  include the Google Play Billing Library and does not declare `com.android.vending.BILLING`.
- Reserved voluntary-donation entry, off by default. Two build-config values in `app/build.gradle.kts`:
  `SUPPORT_URL` (string, empty by default; Gradle property `ata.supportUrl`) and `SHOW_SUPPORT_LINK` (boolean, false
  by default; `ata.showSupportLink`). A "Support ATA" row appears in the About section only when the URL is
  non-empty **and** the flag is true; it just opens the URL in the browser. Keep the flag false for Google Play
  builds: Google Play's Payments policy restricts in-app links to outside payment pages, so it has to be re-checked
  before the row is ever enabled there. A donation never unlocks anything.
- The About section's "Help and feedback" link (`help_url` string, per language) opens the site's Help page.
