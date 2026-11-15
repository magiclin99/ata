# ATA website (GitHub Pages)

Plain HTML and CSS. There's no build step, no JavaScript, no web fonts, no cookies, and no third-party requests.
Light and dark mode follow the system setting. The site targets `https://magiclin99.github.io/ata/`. All internal
links are relative except in `404.html`, which uses `/ata/...` because GitHub serves it at any depth.

| Path | Page |
|---|---|
| `index.html` / `zh-tw/index.html` | Landing page |
| `install/` / `zh-tw/install/` | Mac install, Open Anyway steps, and permissions |
| `faq/` / `zh-tw/faq/` | FAQ (the only place, with the forum posts, that compares ATA with other tools) |
| `tech/` / `zh-tw/tech/` | Technical details: source and licence, how a transfer connects, pairing keys and stored data, installer checks and the signing-certificate fingerprints, network use. All technical wording lives here; the other pages follow the plain-language glossary (TERMS) and link here from the footer. Anchor `#installer` is linked from the install pages. |
| `assets/img/` | Real screenshots only, taken on macOS 14.7: `macos14-warning.png` (Gatekeeper message, English UI), `dmg-window.png` (the 1.0.3 disk-image window, bilingual), `welcome-en.png` / `welcome-zh-tw.png` (ATA 1.0.3's first window; the pairing QR code is blurred because it encodes the Mac's computer name; the small "get the phone app" QR code is left sharp), `firewall-question.png` (the macOS firewall question, English UI). Crop out anything personal, and blur every pairing QR code. Saved as 128-colour PNGs at twice the displayed width. |
| `beta/` / `zh-tw/beta/` | Google Play closed-test page: who can join, how to ask (email with the Google account address), what happens next (opt-in link, install, keep it for 14 days), feedback. Linked from the "coming soon" note on both landing pages. Remove or redirect after the Play launch. |
| `support/` / `zh-tw/support/` | Help and feedback: common fixes, GitHub Issues, email, and what to include in a report. The Android app's "Help and feedback" link opens `https://magiclin99.github.io/ata/support`. No donation content here. |
| `privacy/` | Privacy policy, English (`#en`) and Traditional Chinese (`#zh-tw`) on one page. This is the URL for Play Console: `https://magiclin99.github.io/ata/privacy/` |
| `404.html` | Not-found page |
| `assets/` | `style.css`, icons, and OG images (exported from the ATA brand source files) |

## Hidden slots

No `[[…]]` placeholder is visible on any page. The only one left, `[[SUPPORT_URL]]`, sits inside a `hidden` block.
Three blocks are hidden until they're needed. This file is the only place they're documented: the published
pages carry no maintainer comments, and this README is left out of the Pages deployment.

### Google Play button (switch on at Android launch)

The Android app goes through Google Play's closed test first, so the landing pages say "coming soon to Google Play,
currently in closed testing" and invite testers to email `magiclin99@gmail.com`. At launch:
1. In `index.html` and `zh-tw/index.html`, delete `hidden` from `<a class="btn" id="play-cta" …>`. It already points
   to `https://play.google.com/store/apps/details?id=io.github.magiclin99.ata`. Optionally make it the `primary`
   button.
2. In the same two files, delete the `<p id="android-soon">…</p>` paragraph.
3. In "How it works" step 1, change "(Google Play, coming soon)" / 「（即將在 Google Play 上架）」 to "from Google Play" /
   「從 Google Play」.
4. In the root `README.md`, swap in the two commented lines marked "At Android launch".

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
   wording to the Google Play listing.

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

## Mac download link

Both landing pages and both install pages link the unversioned release asset
`https://github.com/magiclin99/ata/releases/latest/download/ATA.dmg`, which always serves the newest release, so
nothing needs changing when a new version ships. The pages never name the file (TERMS: "the ATA file you just
downloaded"). If a release ever ships without `ATA.dmg`, these links break: check
`curl -sIL -o /dev/null -w '%{http_code}' <url>` after each release.

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
