<h1 align="center">Yank</h1>

<p align="center">
  <strong>A fast, private clipboard for your Mac and iPhone — no subscriptions, no AI gimmicks.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0+-black?style=for-the-badge&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=for-the-badge&logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT">
</p>

> **Status: 1.0.0 is the first public macOS release.** Yank started as a clean‑slate
> evolution of [Buffer](https://github.com/samirpatil2000/Buffer) (MIT, by Samir Patil).
> The macOS app ships as a signed, notarized release. The iOS app + keyboard/share
> extensions and private CloudKit sync are **built** and reach the App Store on their
> own review track.

---

## Why Yank?

- **Fast & lightweight** — small footprint, minimal RAM/CPU, zero third‑party dependencies.
- **Private by design** — your history stays yours. The local clipboard is on‑device; optional
  **cross‑device sync uses your own iCloud** (CloudKit private database), never our servers, and
  known password managers are excluded by default while secret‑marked pasteboard copies are skipped.
- **Free & open source** — everything is free, including cross‑device sync (Mac ↔ iPhone).
  No purchase, no subscription, no account to create. If Yank saves you time, consider
  [sponsoring development](https://github.com/sponsors/The-PatientZero).
- **Text + Images + OCR** — captures anything; extracts searchable text from images/screenshots
  on‑device with Apple Vision.
- **Purposeful, on-device intelligence** — optional Apple Intelligence (macOS 26+): tag & title
  suggestions, Smart Paste rewrites, and natural-language search. On-device via Foundation Models,
  opt-in, no cloud, no account — intelligence stays purposeful, never a gimmick.
- **Organized** — pins, bookmarks, and color‑coded tags with `#` filtering.
- **Multi‑select & multi‑paste** — select several items and paste them together.
- **Large‑content friendly** — chunked previews and disk‑backed storage for multi‑MB text.
- **Native feel** — SwiftUI + AppKit menu‑bar app; quick access with **⇧⌘V**.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⇧⌘V` | Open clipboard history |
| `↑` / `↓` | Navigate items |
| `⇧↑` / `⇧↓` | Expand selection (multi‑select) |
| `↵` Enter | Paste selected item |
| `⌘C` | Copy selected item to clipboard |
| `⌘P` | Pin / unpin selected item |
| `⌘B` | Bookmark / unbookmark selected item |
| `⌘T` | Add tag to selected item |
| `⌘S` | Save image to disk (image items) |
| `⌘⌫` | Delete selected item |
| `⎋` Esc | Close history window |

## Install

Grab the notarized DMG from
[Releases](https://github.com/The-PatientZero/yank/releases/latest), or use Homebrew:

```bash
brew install --cask The-PatientZero/tap/yank
```

The iPhone app ships separately on the App Store (manual submission, on its own review track).
See [`CHANGELOG.md`](CHANGELOG.md) for release history.

## Building from Source

```bash
git clone https://github.com/The-PatientZero/yank.git
cd yank
brew install xcodegen      # the Xcode project is generated from project.yml
xcodegen generate
open Yank.xcodeproj
# Build & run: ⌘R   (set your own Development Team in Signing & Capabilities)
```

**Requirements:** macOS 14+ to run, Xcode 26+ to build (the UI adopts Liquid Glass with
runtime fallbacks below macOS 26), Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`); the iOS app targets iOS 17+. An unsigned source build runs **local‑only**:
CloudKit sync needs the iCloud container entitlement, which only the signed builds (notarized DMG on
Mac, App Store on iPhone) carry.

## Acknowledgments

Yank is based on **[Buffer](https://github.com/samirpatil2000/Buffer)** by **Samir Patil** — an
open‑source (MIT) clipboard manager for macOS. Sincere thanks to Samir and the upstream
contributors whose work this builds on. See [`NOTICE`](NOTICE) for full attribution.

## License

Released under the **MIT License** — see [`LICENSE`](LICENSE). This is a derivative work: the
original copyright notice is retained alongside the current maintainer's, as required by the MIT
License. See [`NOTICE`](NOTICE) for the complete attribution and credits.
