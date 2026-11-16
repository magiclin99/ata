# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue:

- **GitHub private vulnerability reporting** (preferred): on this repository, open
  **Security → Report a vulnerability** ([direct link](https://github.com/magiclin99/ata/security/advisories/new)).
- **Email:** [magiclin99@gmail.com](mailto:magiclin99@gmail.com?subject=ATA%20security) with "ATA security" in the
  subject.

Include the app (Android or Mac) and version, what an attacker needs (being in Bluetooth range, on the same network,
code running on the Mac, …), and the steps to reproduce. Don't send real pairing links, QR codes, pairing keys or
private files; a description or a made-up example is enough. ATA is maintained by one person in spare time: expect a
first reply within about a week. Fixes ship in a new release (both apps are published together on
GitHub Releases), and the report is credited in the release notes unless you prefer otherwise.

## Supported versions

Only the [latest release](https://github.com/magiclin99/ata/releases/latest) gets fixes. It contains both apps
(`ATA.apk`, `ATA.dmg`) and is built automatically from `main`.

## Scope

In scope:

- The Android app (`android-app/`) and the Mac app (`mac-app/`), including pairing, the Bluetooth LE handshake, the
  local-network and WebRTC transfer paths, and how pairing keys and received files are stored.
- The protocol itself ([`SPEC.md`](SPEC.md)): a design flaw is in scope even if both apps implement it faithfully.
- The Mac installer (`mac-app/install.sh`) and its signature check, and the release workflow
  (`.github/workflows/release.yml`): it runs only for pushes to `main` and manual runs by the owner, never for pull
  requests, and checks both apps' signatures against the pinned certificates before publishing.

Out of scope: denial of service by someone in radio range (jamming, flooding advertisements), attacks that need the
phone unlocked in hand or full control of your macOS user account, the public STUN servers ATA contacts, and the
website's hosting (GitHub Pages).

## Trust model, in brief

- **Paired devices only.** Pairing happens by scanning a QR code shown by the Mac. It carries a random 256-bit key
  that only that phone and that Mac know. Every connection starts with a mutual HMAC challenge over Bluetooth LE.
  After that, all messages are encrypted (AES-256-GCM with keys derived per session by HKDF). The local-network file
  stream uses AES-256-GCM records. On WebRTC, the DTLS fingerprints are exchanged inside the already encrypted
  Bluetooth channel. Details: [`SPEC.md`](SPEC.md) and the test vectors in [`spec/vectors.json`](spec/vectors.json).
- **No server.** There are no accounts and no relay (no TURN). Files go directly from the phone to the Mac and never
  reach the developer. Public STUN servers see the devices' IP addresses when the WebRTC path is tried.
- **Key storage.** On Android the pairing key is encrypted with a non-exportable Android Keystore key, and app
  backups are disabled. On the Mac it is in `~/Library/Application Support/io.github.magiclin99.ata.mac/pairings.json`,
  readable only by your user account (the trade-off is explained in [`mac-app/README.md`](mac-app/README.md)).
  Removing a device in the Mac window revokes it.
- **Self-signed Mac builds.** ATA for Mac isn't notarized. Every release is signed with one fixed self-signed
  certificate. The installer refuses any app whose signature doesn't match it. To check a copy yourself:

  ```sh
  codesign --verify --deep --strict -R='identifier "io.github.magiclin99.ata.mac" and certificate leaf = H"3da39545619d4949fa758c6becc77f9e2e3ce65e"' /Applications/ATA.app && echo "signed by ATA"
  ```

  Certificate: [`mac-app/signing/ata-signing-cert.pem`](mac-app/signing/ata-signing-cert.pem), SHA-1
  `3DA39545619D4949FA758C6BECC77F9E2E3CE65E`, SHA-256
  `B7C994A86BB61C91BB8A2F94CBAA33B9BC1C7FE97E646CA3DF38A49E964C9387`. If a "new" ATA ever presents a different
  certificate, don't install it.
- **Android builds** are not on Google Play; they are published as `ATA.apk` on GitHub Releases. Every release is
  signed with the same key, so Android refuses to install an update signed by anyone else over your copy. The
  certificate's SHA-256 is
  `E1242C2CEC30236063FDBE708E9DD97791C3849F2F5932AB963EFD11012D036D`
  ([`android-app/signing/release-cert.sha256`](android-app/signing/release-cert.sha256)). To check a download:
  `apksigner verify --print-certs ATA.apk`.
- **Debug hooks** (SPEC §9) exist only in debug builds. Release builds compile them out, and the Mac release script
  refuses a binary that still contains them.
