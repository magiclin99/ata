# ATA website (GitHub Pages)

Plain HTML and CSS. There's no build step, no JavaScript, no web fonts, no cookies, and no third-party requests.
Light and dark mode follow the system setting. The site targets `https://magiclin99.github.io/ata/`. All internal
links are relative except in `404.html`, which uses `/ata/...` because GitHub serves it at any depth.

| Path | Page |
|---|---|
| `index.html` / `zh-tw/index.html` | Landing page |
| `install/` / `zh-tw/install/` | Mac install, Open Anyway steps, and permissions |
| `faq/` / `zh-tw/faq/` | FAQ (the only place, with the forum posts, that compares ATA with other tools) |
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
