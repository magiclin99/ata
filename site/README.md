# ATA website (GitHub Pages)

Plain HTML and CSS. There's no build step, no JavaScript, no web fonts, no cookies, and no third-party requests.
Light and dark mode follow the system setting. The site targets `https://magiclin99.github.io/ata/`. All internal
links are relative except in `404.html`, which uses `/ata/...` because GitHub serves it at any depth.

| Path | Page |
|---|---|
| `index.html` / `zh-tw/index.html` | Landing page |
| `install/` / `zh-tw/install/` | Mac install, Open Anyway steps, and permissions |
| `faq/` / `zh-tw/faq/` | FAQ (the only place, with the forum posts, that compares ATA with other tools) |
| `assets/img/` | Real screenshots only, taken on macOS 14.7: `macos14-warning.png` (Gatekeeper message, English UI), `dmg-window.png` (the 1.0.3 disk-image window, bilingual), `welcome-en.png` / `welcome-zh-tw.png` (ATA 1.0.3's first window; the pairing QR code is blurred because it encodes the Mac's computer name; the small "get the phone app" QR code is left sharp), `firewall-question.png` (the macOS firewall question, English UI). Crop out anything personal, and blur every pairing QR code. Saved as 128-colour PNGs at twice the displayed width. |
| `android/` / `zh-tw/android/` | Android phone install: download button for the install file (`ATA.apk`, phones only), a QR code that opens this page on the phone (desktop only), the step-by-step install with the phone's own prompts, the Samsung Auto Blocker note (`#samsung`), and how to update. |
| `beta/` / `zh-tw/beta/` | Redirects to `android/` / `zh-tw/android/`. Mac 1.0.3's "get the phone app" QR code and link open these URLs, so keep them. (They were the Google Play closed-test pages until 2026-11-16, when the owner decided ATA won't go on Google Play.) |
| `support/` / `zh-tw/support/` | Help and feedback: common fixes, GitHub Issues, email, and what to include in a report. The Android app's "Help and feedback" link opens `https://magiclin99.github.io/ata/support`. No donation content here. |
| `privacy/` | Privacy policy, English (`#en`) and Traditional Chinese (`#zh-tw`) on one page. Both apps link here: `https://magiclin99.github.io/ata/privacy/` |
| `404.html` | Not-found page |
| `assets/` | `style.css`, icons, and OG images (exported from the ATA brand source files) |

## Hidden slots

No `[[…]]` placeholder is visible on any page. The only one left, `[[SUPPORT_URL]]`, sits inside a `hidden` block.
Two blocks are hidden until they're needed. This file is the only place they're documented: the published
pages carry no maintainer comments, and this README is left out of the Pages deployment.

### Demo video (switch on when a real recording exists)

In both landing pages, put the video (self-hosted under `assets/`, for example
`<video controls playsinline preload="metadata" poster="assets/demo-poster.jpg" src="assets/demo.mp4"></video>`,
with `../assets/` in `zh-tw/`) inside
`<section id="demo-slot" hidden>` and delete `hidden`. Use only real screen recordings or real footage of a Mac.
Don't embed YouTube unless you also add it to the privacy policy.

## Support slot (disabled)

A voluntary-support link (platform: Recur) is reserved but not enabled. Both landing pages contain
a `<section id="support-slot" hidden>` block, preceded by a one-line neutral comment, with the link `[[SUPPORT_URL]]`. Because
of the `hidden` attribute, browsers render nothing and the placeholder never shows.

To switch it on once the support URL exists:
1. In `index.html` and `zh-tw/index.html`, replace `[[SUPPORT_URL]]` with the real URL.
2. In the same two files, delete the word `hidden` from `<section aria-labelledby="support" id="support-slot" hidden>`.
3. Optionally add a footer link (`<a href="./#support">Support ATA</a>` / `<a href="./#support">贊助 ATA</a>`).
4. Keep the copy as it is: support is voluntary, unlocks nothing, and the app stays free. Don't add support
   wording to the download pages or the apps.

To switch it off again, put `hidden` back.

## Deploying from `site/`

GitHub Pages can publish "from a branch" only from the repo root or `/docs`. To publish this folder as it is, use a
GitHub Actions workflow. Choose Settings → Pages → Source: **GitHub Actions**. The workflow is
`.github/workflows/pages.yml` at the repository root:

```yaml
name: Pages
on:
  push:
    branches: [main]
    paths: ["site/**"]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency: { group: pages, cancel-in-progress: true }
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: { name: github-pages, url: "${{ steps.d.outputs.page_url }}" }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/upload-pages-artifact@v3
        with: { path: site }
      - id: d
        uses: actions/deploy-pages@v4
```

Preview locally with `python3 -m http.server -d site 8000`, then open `http://localhost:8000/`. The `404.html`
links assume the `/ata/` prefix, so they only resolve after deployment.

## Download links

Both apps are downloaded from the newest GitHub release, by unversioned names that never go stale:

- Mac: `https://github.com/magiclin99/ata/releases/latest/download/ATA.dmg` (both landing pages, both install pages)
- Android phone: `https://github.com/magiclin99/ata/releases/latest/download/ATA.apk` (the phone block of both landing
  pages, both `install/` pages, both `android/` pages)

The pages never ask people to pick a file; they name it once ("the ATA install file (ATA.apk)"). If a release ever
ships without either file, these links break: check `curl -sIL -o /dev/null -w '%{http_code}' <url>` after each
release.

`assets/img/qr-android-en.svg` and `qr-android-zh-tw.svg` encode only `https://magiclin99.github.io/ata/android/` and
`https://magiclin99.github.io/ata/zh-tw/android/`. They were generated locally with segno 1.6.1 (error correction M,
dark `#1b2348` on white) and checked by decoding them. Regenerate them if the page address changes.

## Phone install wording

The `android/` steps quote the phone's own screens. Checked 2026-11-16 against official sources; anything not listed
here is described in plain words, and the pages say the wording may differ by brand and Android version.

| Screen | English | 繁體中文 | Source |
|---|---|---|---|
| Blocked from this source | "For your security, your phone currently isn't allowed to install unknown apps from this source." → Settings | 「為了安全起見，你的手機目前無法安裝此來源提供的不明應用程式。」→「設定」 | AOSP PackageInstaller `untrusted_external_source_warning` |
| The switch | Allow from this source | 允許這個來源的應用程式 | AOSP Settings `external_source_switch_title` |
| Install / update | "Do you want to install this app?" → Install; "Do you want to update this app?" → Update; Open | 「要安裝這個應用程式嗎？」→「安裝」；「要更新這個應用程式嗎？」→「更新」；「開啟」 | AOSP PackageInstaller |
| Play Protect | Google Play Protect may recommend scanning an app it hasn't seen | 「Google Play 安全防護」可能建議掃描 | support.google.com/googleplay/answer/2812853 (exact button labels not published, so not quoted) |
| Samsung | Settings → Security and privacy → Auto Blocker (on by default on phones that ship with One UI 6.1.1 or later; also blocks updates from outside stores) | 「設定」→「安全性與隱私權」→「自動封鎖程式」 | samsung.com/uk and samsung.com/tw support article "Protect your Galaxy device with the Auto Blocker feature" |

Not verified: the browser's own download prompt, the name of the Downloads/My Files app, Samsung's version of the
"blocked from this source" dialog, and other brands (Xiaomi, OPPO, ASUS…).

The Mac app opens `faq/#firewall` (both languages). Keep that anchor. The install pages' `#s2` and `#s3` anchors are
linked from the FAQ and Help pages.

## Mac app labels (sync with each Mac release)

The pages quote the labels of the **released** Mac app (1.0.3, checked against `mac-app/Sources/ATA/*.swift` and
`mac-app/Resources/zh-Hant.lproj/Localizable.strings` at tag `v1.0.3`):

| English | 繁體中文 | Quoted in |
|---|---|---|
| Pair a Phone… | 配對手機… | `faq/`, `support/` (both languages) |
| Show a New QR Code | 產生新的 QR code | `faq/`, `support/` |
| Open at Login | 登入時打開 | `install/`, `faq/`, and the permissions table in `privacy/` (described, both halves) |
| Show ATA in the Dock | 在 Dock 顯示 ATA | `faq/` |
| Move ATA to Applications first | 請先把 ATA 移到「應用程式」 | `faq/`, `support/` |
| Quit ATA | 結束 ATA | `install/`, `faq/` |
| Drag ATA to Applications (disk-image window) | 把 ATA 拖到「應用程式」 | `install/` (screenshot) |

The pages also quote the phone app's "Pair with a Mac" / 「與 Mac 配對」 and its share target "Send to Mac" /
「傳到 Mac」 (`android-app/.../strings.xml`: `pair_button`, `share_label`), and the macOS firewall question
("accept incoming network connections" / 「接受傳入的網路連線」, as the Mac app quotes it).
When a Mac release renames any of these, update the table and grep for the old wording in `site/`. The screenshots
in `assets/img/` show 1.0.3; retake them if the windows they show change.
