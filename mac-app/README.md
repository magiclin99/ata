# ATA for Mac

ATA receives photos and files sent from your Android phone to your Mac computer. The phone and the Mac must be
within Bluetooth range of each other; the files themselves travel over your local network. ATA for Mac is free and
open source (MIT). It needs macOS 14 or later and runs on Apple silicon and Intel Macs.

To send files you need the ATA app on your Android phone (coming soon to Google Play, with a closed test
before release; see the [main README](../README.md#get-the-android-app)). Both apps are completely free: no
purchases, no subscriptions, no ads, no limits.

## Install

**Recommended — one line in Terminal:**

```sh
curl -fsSL https://github.com/magiclin99/ata/releases/latest/download/install.sh | sh
```

The script downloads the latest `ATA-<version>.zip` from
[GitHub Releases](https://github.com/magiclin99/ata/releases) and checks its SHA-256 checksum. It then checks that the
app is intact and signed with ATA's own certificate: the requirement pinned in the script is the bundle id plus the
certificate's SHA-1, `3DA39545…E65E` (see "Signing"). Anything else is refused, and nothing is installed. Then it
quits ATA if it is running, replaces `/Applications/ATA.app` and opens it. Read it first if you like
([`install.sh`](install.sh)); it is safe to run again, which is also how you update. Add `-s -- --dry-run` after
`sh` to only download and verify. Because Terminal downloads are not marked as "downloaded from the internet", macOS
opens the app without the Gatekeeper warning described below.

**Or download it with your browser:** get `ATA-<version>.dmg` (or `.zip`) from
[Releases](https://github.com/magiclin99/ata/releases), drag **ATA** into **Applications**, then open it the first
time like this (ATA is signed with its own certificate, not by an Apple Developer ID, and is not notarized by Apple):

- **macOS 15 (Sequoia) and later:** double-click ATA. macOS says it can't verify the app — click **Done**. Open
  **System Settings → Privacy & Security**, scroll down to the message about ATA and click **Open Anyway**, then
  confirm with your password or Touch ID.
- **macOS 14 (Sonoma):** in Applications, **Control-click** (right-click) ATA, choose **Open**, then click **Open**
  in the dialog.

This is needed once per download. To check what you downloaded, compare `shasum -a 256 ATA-<version>.dmg` with
`SHA256SUMS.txt` on the release page. To check who signed the app:

```sh
codesign --verify --deep --strict -R='identifier "io.github.magiclin99.ata.mac" and certificate leaf = H"3da39545619d4949fa758c6becc77f9e2e3ce65e"' /Applications/ATA.app && echo "signed by ATA"
```

**Uninstall:** quit ATA (menu or window → Quit ATA), delete `/Applications/ATA.app`. To also remove pairings and
settings: delete `~/Library/Application Support/io.github.magiclin99.ata.mac` and run
`defaults delete io.github.magiclin99.ata.mac`.

## Using ATA

1. Open ATA. The first time, the window shows a short welcome and the pairing QR code right away. On your phone,
   open ATA, tap **Pair with a Mac**, and scan it. If the phone doesn't have ATA yet, a second, separate QR code in
   the same window opens the page to get it (one constant, `Links.getAndroidApp`, to switch to the Play Store at
   launch). After pairing, the window shows the phone's name and what to do next.
   - The first pairing turns on **Open at Login** (only for the copy in /Applications, and never if you already set
     it yourself), and says so in one sentence with the switch right there. If you turn it off, ATA never turns it
     back on. Without it, after a restart ATA isn't running and the phone can't find the Mac.
   - If the macOS firewall is on, ATA explains the "accept incoming network connections" question and then makes
     macOS ask it right away (it listens for a moment), instead of in the middle of the first transfer. On
     macOS 15 and later it does the same for the "find devices on your local network" question (see Permissions).
2. On your phone, tap Share in Photos or any app and choose **Send to Mac**. Files arrive in your Downloads folder (you can change that in
   the window). A notification says where they were saved; click it to see the file in Finder. The window also lists
   the latest files with a **Show in Finder** button.

ATA keeps running in the background after you close its window, and it shows a normal icon in the Dock: click it (or
open ATA again from Applications, Spotlight or Launchpad) to get the window back. It also has an icon in the menu
bar, but when the menu bar is full macOS hides icons behind the camera notch, so the Dock icon and the window are the
dependable way back. If you prefer ATA only in the menu bar, turn off **Show ATA in the Dock** in the window's
settings; ATA then shows a Dock icon only while one of its windows is open.

The interface is in English and Traditional Chinese (it follows your macOS language). Its wording follows the
project's plain-language glossary: no technical terms, and every problem is one sentence about what happened plus one
thing to try.

**Updates:** ATA 1.0 does not update itself. **Check for Updates…** opens the Releases page; run the install command
again (or download the new dmg) to update. Pairings and settings are kept.

## Permissions

macOS asks for these the first time they are needed. ATA explains each one in plain words just before it is asked.

- **Bluetooth** — required; it's how your phone finds this Mac. On first launch the window says that macOS is about
  to ask and why, then macOS asks. If you clicked Don't Allow, the window shows the steps (System Settings →
  Privacy & Security → Bluetooth → turn on ATA) and a button that opens that page. Releases are all signed with the
  same certificate, so updating ATA doesn't ask again.
- **Incoming network connections** (only if the macOS firewall is on) — click **Allow** so your phone can deliver
  files over the same Wi-Fi. Until the first such transfer works, the welcome and pairing windows mention this
  question. If the firewall blocked a transfer, ATA says "Your Mac's firewall is blocking your phone, so sending is
  slower." with a **How to Fix…** link to the [FAQ entry](https://magiclin99.github.io/ata/faq/#firewall): allow ATA
  in System Settings → Network → Firewall → Options, remove duplicate ATA entries left by older versions, then quit
  and reopen ATA. ATA never changes firewall settings itself.
- **Local network** (macOS 15 and later) — files arriving over the same Wi-Fi are incoming connections, which
  macOS doesn't ask about (Apple TN3179). macOS does ask when ATA has to fall back to the internet path while the
  phone is on the same Wi-Fi, because that sends to the phone's local address. ATA brings that question forward to
  just after the first pairing (TN3179's method: connect a UDP socket to a local address; nothing is sent). This
  couldn't be tested here: the development Mac runs macOS 14, which has no such question.
- **Notifications** — asked after the first transfer; optional.
- **Open at Login** works best when ATA is in /Applications.

ATA does not use the Keychain, so there is no Keychain password prompt, also not after updates.

### Where pairing keys are stored

Each paired phone has a 32-byte key. ATA keeps these keys in
`~/Library/Application Support/io.github.magiclin99.ata.mac/pairings.json`. The folder is readable only by your user
account (permissions 700) and so is the file (600). Writes are atomic, and keys never appear in logs. The folder is
marked "excluded from backup" (when it is created and again at every launch), so Time Machine doesn't copy the keys;
after a restore, pair the phone again.

The trade-off, honestly: the keys are protected by file permissions for your user account, not by the Keychain.
Programs running as your user, and anyone with your account or an unencrypted backup of it, could read them. What a
key allows is limited: a phone that has it, and is within Bluetooth range, can send files to this Mac (they land in
your save folder). It does not give access to anything on the Mac or the phone. If you are worried a key was
copied, remove the phone in the ATA window and pair it again. The Keychain was the first choice, but macOS ties
Keychain access for apps that are not signed by an Apple Developer ID to the exact build. Every update would then ask
you for your login password once per paired phone (see "Signing").

Builds before 1.0 stored keys in the Keychain. On first launch, 1.0 imports any of those that it can read without
asking, then deletes them from the Keychain. Ones it can't read silently are left alone, and that phone has to be
paired again.

---

## For contributors

| Path | What |
|---|---|
| `Sources/ATACore` | No UI. Crypto + codecs (`Crypto.swift`, `Framing.swift`), pairing + file store and one-time Keychain import (`Pairing.swift`), session state machine (`Engine.swift`), BLE peripheral, LAN TCP receiver (`Transfer.swift`), WebRTC receiver, record → file writer (`FileReceiver.swift`), debug loopback signaling (`LoopbackSignal.swift`). |
| `Sources/ATA` | SwiftUI app: menu bar extra, Dock icon policy and pairing window (`ATAApp.swift`), main window with the first-launch welcome (`MainWindow.swift`), state, actions and the plain-language error mapping (`AppModel.swift`), notifications (`Notifier.swift`), read-only firewall check (`Firewall.swift`). |
| `Resources` | `Info.plist`, icon, `en.lproj` / `zh-Hant.lproj` (`Localizable.strings`, `InfoPlist.strings`; keys are the English source strings). |
| `Sources/ATAFakePhone` | Scripted phone (handshake, encrypted messages, LAN TCP and WebRTC sender, tamper switches). Used by tests and the CLI. |
| `Sources/ata-fakephone` | CLI around `ATAFakePhone` for regression runs against a running debug app. |
| `Tests/ATACoreTests` | Vectors (`../spec/vectors.json` read in place), framing, end-to-end engine tests, WebRTC loopback. |
| `scripts/` | `build-app.sh` (build + bundle + sign), `release.sh` (signed release + zip/dmg/checksums), `make-signing-identity.sh` (one-time certificate), `make-icon.sh`, `test-install.sh` (installer authenticity test), `check-strings.py` (every UI string translated, no glossary "never show" words). |
| `signing/ata-signing-cert.pem` | Public half of the release certificate (pinned by `release.sh`). |
| `install.sh` | The `curl … \| sh` installer (also attached to every release). |
| `../.github/workflows/release-mac.yml` | (repository root) Tag `v*` → test, sign, publish the release. |

Bundle id `io.github.magiclin99.ata.mac`, version in `Resources/Info.plist` (`CFBundleShortVersionString` /
`CFBundleVersion`). Pairing keys in `~/Library/Application Support/io.github.magiclin99.ata.mac/pairings.json`;
settings in the `io.github.magiclin99.ata.mac` defaults domain.

**Reserved support link.** `ATASupportURL` in `Resources/Info.plist` is empty, so there is no "Support ATA…" item
(zh-Hant 「支持 ATA…」). Putting a valid `https://` URL there adds that item to the menu and the main window. It
only opens the URL in the default browser; supporting never unlocks or changes anything in the app. The validation
is in `Sources/ATACore/SupportLink.swift` (tests: `SupportLinkTests`). Missing, empty, non-https or malformed values
keep the item hidden, and a test asserts that the shipped value is empty.

### Build from source

Needs Xcode 16 (Swift 6 toolchain) on macOS 14+. The WebRTC xcframework is downloaded by SwiftPM on the first build.

```sh
swift test                      # unit + loopback tests (VectorTests read ../spec/vectors.json)
scripts/build-app.sh            # debug (SPEC §9 hooks on), ad-hoc signed  → build/ATA.app
scripts/build-app.sh release    # hooks compiled out, ad-hoc signed        → build/ATA.app
```

`build-app.sh` runs `swift build`, assembles the bundle (`Contents/MacOS/ATA`, `Info.plist`, icon, localizations,
license files, `Contents/Frameworks/WebRTC.framework`), adds the `@executable_path/../Frameworks` rpath and signs
inside-out. It signs ad-hoc unless `ATA_SIGN_IDENTITY` is set (see the header of the script for
`ATA_SIGN_KEYCHAIN`, `ATA_SIGN_KEYCHAIN_PASSWORD_FILE`, `ATA_APP_OUT`, `ATA_UNIVERSAL`). An ad-hoc build is a new
app to macOS every time: expect the Bluetooth prompt after each rebuild.

`scripts/make-icon.sh` regenerates `Resources/AppIcon.icns` and the menu bar template image
(`Resources/MenuBarIcon*.png`) from the brand assets in `Resources/brand/` (copied from the project's brand kit,
whose generator is the source of truth). The menu bar shows the ATA mark, and switches to a status glyph only while
ATA is receiving or Bluetooth needs attention. SF Symbols appear only as interface glyphs like that, never as the icon
or logo.

### Release

```sh
scripts/release.sh     # → dist/ATA-<v>.zip, ATA-<v>.dmg, ATA.dmg, *.sha256, SHA256SUMS.txt, install.sh
```

Builds a universal (arm64 + x86_64) release with the debug hooks compiled out, signs it with the release certificate,
and refuses to continue unless the designated requirement is exactly
`identifier "io.github.magiclin99.ata.mac" and certificate leaf = H"<SHA-1 of signing/ata-signing-cert.pem>"`, the
framework is signed with the same certificate, and the binary contains no debug hooks. It then builds the zip and
dmg, signs the dmg, writes checksums, mounts the dmg and verifies the app inside. The dmg window has a background with an
arrow from ATA to Applications (`scripts/make-dmg-background.swift` → `Resources/dmg/background.tiff`). The Finder
layout is a stored file, `Resources/dmg/DS_Store`, made once by `scripts/make-dmg-layout.sh` (dmgbuild from a throwaway
venv, hash-pinned in `scripts/requirements-dmg.txt`, settings in `scripts/dmg-settings.py`). Releases then need only
`hdiutil create`. That avoids copying the app onto a writable mounted image, which a security scanner can keep busy.
`ATA.dmg` is the same file under a fixed name, so the website can link `releases/latest/download/ATA.dmg`. The zip carries no resource forks or
`__MACOSX/` entries. The signing keychain is locked again as soon as signing is done.

`scripts/test-install.sh` checks the installer's authenticity check with `--dry-run` against local fake releases.
It touches neither /Applications nor a running ATA. The release-signed app must be accepted. These must be refused:
an ad-hoc re-signed copy, a copy signed by another self-signed certificate with the same name, a modified copy, and a
bad checksum.

Locally it uses `~/ata-secrets/mac/ata-signing.keychain-db` (created once by `scripts/make-signing-identity.sh`).
In CI, pushing a tag `v<version>` that matches `CFBundleShortVersionString` runs
`.github/workflows/release-mac.yml` (at the repository root), which needs two repository secrets:

| Secret | Value |
|---|---|
| `MAC_SIGNING_P12_BASE64` | contents of `~/ata-secrets/mac/github-secret-p12-base64.txt` |
| `MAC_SIGNING_P12_PASSWORD` | contents of `~/ata-secrets/mac/p12-password.txt` |

### Signing (no Apple Developer account)

Every release is signed with the same self-signed certificate ("ATA Release Signing (magiclin99)", SHA-1
`3DA39545619D4949FA758C6BECC77F9E2E3CE65E`, valid until 2046). Its private key lives only in `~/ata-secrets/mac/`
and in the GitHub secret. **If the key is lost, the next release looks like a different app to every Mac.**

- codesign accepts the untrusted self-signed identity without any trust-settings change, but only finds it when its
  keychain is on the user keychain search list; the scripts add the dedicated keychain for the signing step and put
  the previous list back on exit, then lock that keychain again. The login keychain is never touched. In CI the
  `.p12` is imported with `security -i`, so no password appears in a process argument list.
- Hardened runtime is not enabled. A self-signed certificate has no Team ID, so library validation would reject the
  embedded WebRTC.framework unless it were switched off again with an entitlement. That would add little protection
  in return for new Bluetooth and network entitlement requirements to verify.
- The resulting designated requirement depends only on the bundle id and the certificate, so it is identical for
  every build (verified across separately built debug and release binaries with different cdhashes).
- **Bluetooth (TCC)** stores that designated requirement, so the approval is expected to carry over to updates.
- **Keychain (why ATA doesn't use it):** a login-keychain item's access list stores the designated requirement,
  but macOS also adds a *partition ID* to every item an app creates. For apps without an Apple Team ID (ad-hoc or
  self-signed) that partition is `cdhash:<hash of that exact build>`. A differently built copy with the same
  certificate was observed to get the "wants to access key … in your keychain" password prompt. So pairing keys are
  kept in a file (see "Where pairing keys are stored").

### Debug hooks and the fake phone

Launch through `open` so macOS attributes Bluetooth to ATA itself rather than to the terminal (debug builds only):

```sh
open -n build/ATA.app --args \
    --pairing-uri-file /tmp/ata/uri.txt \   # enter pairing mode, write the ata://pair URI here (no window)
    --log-file /tmp/ata/ata.log \           # timestamped protocol log
    --save-dir /tmp/ata/save \              # override the save folder for this run
    --debug-signal-port 47990               # optional: BLE stand-in on 127.0.0.1 for ata-fakephone
                                            # optional: --debug-show-pairing opens the pairing window
```

Only one ATA runs at a time: a second copy (`open -n`, another path) asks the running one to show its window and
quits, so quit the installed ATA first. Quit from the menu, or `pkill -f build/ATA.app/Contents/MacOS/ATA` (SIGTERM
is handled like Quit). Release builds log to stdout: `open --stdout /tmp/ata.log build/ATA.app`.

`--debug-signal-port` accepts the same messages BLE would carry, framed as 4-byte big-endian length ‖ message
bytes, on 127.0.0.1 only. The engine treats such a connection exactly like a subscribed BLE central.

```sh
FP=.build/arm64-apple-macosx/debug/ata-fakephone      # built by scripts/build-app.sh
$FP --signal-port 47990 --uri-file /tmp/ata/uri.txt --pair-only          # pair only (session ends ok=true)
$FP --signal-port 47990 --uri-file /tmp/ata/uri.txt --count 3 --mib 5   # pair, then send 3 x 5 MiB over LAN TCP
$FP --signal-port 47990 --count 2 --mib 1                                # stored key (state file), LAN TCP
$FP --signal-port 47990 --files ~/Pictures/a.jpg ~/b.pdf                 # real files
$FP --signal-port 47990 --wrong-sid | --bad-sha 0 | --corrupt-record 2 | --truncate 100000 | --bad-mac
$FP --signal-port 47990 --rtc --count 1 --mib 4                          # WebRTC path (see firewall note)
```

The last line is `RESULT ok=<bool> via=<lan|rtc|none> files=<n> bytes=<n> ms=<n>`, the same format as the Android
app. The phone identity and key are kept in `$TMPDIR/ata-fakephone-state.json` (`--state` to change).

With the macOS application firewall on, `ata-fakephone` (an unsigned CLI) can't receive the inbound UDP that ICE
needs, so `--rtc` fails with "ICE failed". Allow the binary in the firewall, or run the same path from the
Apple-signed test runner:

```sh
ATA_LIVE_SIGNAL_PORT=47990 ATA_LIVE_STATE=$TMPDIR/ata-fakephone-state.json swift test --filter LiveAppTests
```

## Protocol interpretation notes

These are the choices made where SPEC.md is silent or ambiguous. The Android sender has to agree with them.

1. `hello` = `{"t":"hello","v":2,"id":"<32 lowercase hex>","n":"<std base64, padded, of 16 bytes>"}`. A fresh
   nonceM is sent on every TX subscription. If the phone re-subscribes on the same connection, the Mac treats it as
   a new link.
2. `auth` parsing: `id` hex in either case; `n` and `mac` are standard base64 (padding optional on receive); `pairing`
   has to be a JSON boolean, and a missing one counts as false. A missing or empty `name` becomes "Android phone". An
   optional `v` other than 2 gets `bad_version`. A malformed `auth` (bad id/n/mac) also gets `bad_version`, because
   the spec has no other reason for it.
3. Check order: busy → (pairing: QR code still valid, else `pairing_expired`) / (stored key, else
   `unknown_device`) → HMAC (constant time, else `bad_mac`). A busy Mac answers `busy` before looking at the key.
4. A failed pairing attempt doesn't use up the QR code. Only a successful one does. K goes into the pairing store
   *before* `auth_ok` is sent. If that write fails, the reply is `auth_fail` `pairing_expired`.
5. "Then disconnect": CoreBluetooth gives a peripheral no way to disconnect a central. After `auth_fail`, a decrypt
   failure or the end of the session, the Mac stops serving that link (ignores writes, sends nothing more). The phone
   has to disconnect GATT itself.
6. Each BLE connection carries one session. After `bye`, or any other end of the session, the link is dead. The
   next transfer needs a new connection (or re-subscription) and a new `hello`.
7. Encrypted-message counters start at 0 with the first message after `auth_ok` in each direction (`auth_ok` is
   plaintext). An encrypted message that decrypts but isn't a JSON object with `t` is ignored. An unknown `t` is
   ignored too.
8. `send`: `files` has to be a non-empty array of `{name: string, size: integer ≥ 0}`. If `total` differs from the
   sum, the sum wins. Integers are JSON numbers without a fraction (`3.0` is accepted, `"3"` and `true` are not).
   Possible `reject` reasons: `bad_request`, `no_space` (needs sum + 64 MiB free), `save_folder_unavailable`,
   `already_accepted`.
9. `accept`: `tcpPort` is a JSON integer and `lan` is an array of dotted IPv4 strings (it can be empty). Each
   session gets an ephemeral port on 0.0.0.0. If the listener can't start, the reply is `tcpPort:0, lan:[]` and the
   phone should go straight to WebRTC. The phone has 5 s after connecting to send the 16-byte sid. With a wrong sid,
   only that connection is closed and the listener keeps waiting. The first connection with the right sid carries the
   files, and further connections are refused.
10. The Mac doesn't check the record stream against the `send` list. Progress is measured against the `send` sum.
11. Limits are enforced strictly. TCP frame N must be 17 to 1 MiB, and a `0x02` body is at most 64 KiB. On WebRTC, a
    `0x02` body is at most 16 KiB and records must be binary messages.
12. `0x01` = `{"name","size"}`, and extra fields are ignored. The `0x03` sha256 comparison ignores case. `0x04` replies
    are `{"ok":true}`, `{"error":"sha256 mismatch","ok":false}` or `{"error":"size mismatch: got X of Y bytes","ok":false}`.
13. A per-file failure (sha or size mismatch) gets a `0x04` with `ok:false`, and the stream continues. Other errors
    end the session with an error after the Mac closes the TCP connection or data channel and deletes the partial
    file: a GCM failure, data before `0x01`, more data than `size`, an oversized record, an unknown type, `0x04` from
    the phone, or a record after `0x05`. Files saved earlier stay.
14. After `0x05` the Mac sends nothing and closes the TCP connection. It waits up to 10 s for `bye` before ending
    the session as a success. If `bye` overtakes the end of the stream, it waits up to 3 s for `0x05`.
15. If BLE disconnects mid-transfer, the Mac aborts the transfer even if TCP is healthy. The phone must keep GATT
    connected until it has sent `bye`.
16. Mac timeouts: `auth` within 15 s of `hello` (not counting time spent in the pairing store); 30 s of
    session idle time (no BLE message and no file record); the data channel open within 20 s of `rtc_answer`; ICE
    gathering 5 s at most.
17. `rtc_offer` is accepted only after `accept`, and only while no data has arrived over LAN (otherwise the reply is
    `rtc_error`). A second offer replaces the first. `rtc_answer.sdp` is the complete SDP with candidates.
18. `bye` = `{ok: bool, via: string|null, error: string|null}`. A session counts as successful when `0x05` was
    received. A `bye` before any `send` (a pairing-only session) isn't an error.
19. Pairing URI: the parameters are in the order `v, id, name, k`. `name` is the macOS Computer Name,
    percent-encoded per RFC 3986 from UTF-8 with only unreserved characters left literal (a space is `%20`, never
    `+`).
20. Advertised local name: `ATA-` + 8 lowercase hex characters. A 128-bit service UUID already fills most of the
    31-byte legacy advertisement, so macOS may move or truncate the name into the scan response. Android should scan
    actively and fall back to `hello.id`.
21. File names keep the last path component after `/` or `\`. Leading dots are stripped, `:` and control characters
    become `_`, an empty name becomes `file`, and names are cut to 240 UTF-8 bytes, keeping the extension. A
    collision becomes `name (1).ext`. Temp files are hidden `.ata-<hex>.part` files in the save folder.

---

Android is a trademark of Google LLC. Mac is a trademark of Apple Inc., registered in the U.S. and other countries and regions. ATA is not affiliated with or endorsed by Apple or Google.
