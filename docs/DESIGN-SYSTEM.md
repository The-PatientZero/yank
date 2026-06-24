# Yank — Design System

A reference for Yank's visual language: colour, type, spacing, motion, materials, and the
reusable SwiftUI components built on them. Every value here is extracted from the source
and cited to its file, so this document stays verifiable rather than aspirational.

> **Source of truth is the code, not this file.** The numeric scales live in
> [`Shared/DesignScale.swift`](../Shared/DesignScale.swift) (compiled into both the macOS and
> iOS targets); the ink table in [`Shared/YankInk.swift`](../Shared/YankInk.swift); the theme
> accents in [`Shared/Theme.swift`](../Shared/Theme.swift); and the macOS colour bridges,
> motion, materials, and styles in [`Views/DesignSystem.swift`](../Views/DesignSystem.swift).
> When a value here disagrees with those files, the files win — update this doc.

## Principles

- **Warm paper, not system grey.** Neutrals are a warm off-white/charcoal "paper" palette, replacing hard system dividers and backgrounds.
- **Native metrics.** The type scale is aligned to native macOS control metrics; the system font (San Francisco) is used throughout. macOS uses a fixed scale; iOS scales the same roles with Dynamic Type.
- **One 2pt grid, one radius scale, one motion language.** Shared numeric scales mean a tweak lands in both platforms at once and can't drift apart.
- **AA-verified, in the source.** Foreground inks carry their measured contrast ratios as comments; colour never carries meaning alone (e.g. tag pills use `.primary` text, hue is identity only).
- **Glass on the control layer only.** Liquid Glass (macOS 26+) lives on floating navigation/controls above content — never on scrollable content — with a vibrancy fallback below 26.

---

## Colour

### Theme accents

Eight user-selectable accents, applied as `.tint` at the window roots, to the "Yank." dot, and
to every selection / focus / active state. **Amber is the default** (matches the app icon).
Source: [`Shared/Theme.swift`](../Shared/Theme.swift).

| Theme | Fill (`color`) | Foreground light | Foreground dark | Glyph-on-fill (`onAccent`) |
|---|---|---|---|---|
| **amber** *(default)* | `#FBBF24` | `#826312` | `#FBBF24` | near-black `#1A1916` |
| terracotta | `#E2683C` | `#B24A22` | `#F08A5D` | near-black `#1A1916` |
| rose | `#F43F5E` | `#C02B47` | `#FB7185` | near-black `#1A1916` |
| plum | `#A855F7` | `#8B3FD6` | `#C084FC` | near-black `#1A1916` |
| indigo | `#6366F1` | `#4F46E5` | `#818CF8` | white |
| teal | `#14B8A6` | `#0A7066` | `#2DD4BF` | near-black `#1A1916` |
| forest | `#22A06B` | `#0A7853` | `#34D399` | near-black `#1A1916` |
| graphite | `#64748B` | `#5C6A7F` | `#94A3B8` | white |

**`color` vs `foreground` — a hard rule.** The saturated `color` is a **fill behind primary
text only** and must never be used as a foreground/glyph (amber on white is only 1.67:1). The
appearance-aware `foreground` is the WCAG-AA-verified value for any glyph, label, or `.tint`.
`onAccent` is the glyph colour that sits *directly on* the saturated swatch (white clears AA
only on the two darkest accents — indigo, graphite — so the rest take warm near-black).

- **`selectionFill`** = `color.opacity(0.22)` — tinted fill behind a focused selection row.

### Neutral "paper" surfaces

Source: [`Shared/YankInk.swift`](../Shared/YankInk.swift), packed `0xRRGGBB` `(light, dark)` pairs.

| Token | Light | Dark | Use |
|---|---|---|---|
| `surface` | `#F6F2EC` | `#1A1916` | Window / list background |
| `raised` | `#FCF9F4` | `#232220` | Bars, inputs, cards — barely lifted |
| `hairline` | `#E7E0D5` | `#33302B` | Warm separator (replaces system dividers) |

### Semantic inks

All tuned per-appearance to clear WCAG-AA; ratios are recorded in the source.

| Token | Light | Dark | Notes |
|---|---|---|---|
| `bookmark` | `#9A6F08` | `#FFCC4D` | Gold glyph; ≥3:1 non-text on paper (4.05:1 surface / 4.3:1 raised) |
| `bookmarkFill` | `#8A6400` | `#8A6400` | Fill behind a white glyph (iOS swipe); white → 5.38:1; doesn't adapt |
| `textTertiary` | `#6E665A` | `#9C948A` | Quiet metadata / hints, ~5:1 |
| `codeText` | `#4A453E` | `#C4BCB2` | Monospaced previews & long-text body, ~8:1 light / ~7:1 dark |
| `danger` | `#C2371F` | `#FF6B5A` | Destructive / error (warm-leaning red) |
| `success` | `#2F855A` | `#48BB78` | Positive status / confirmations |
| `oversize` | `#B45309` | `#C2410C` | "Large" badge fill; white → 5.02:1 / 5.18:1 |

### Neutral opacity tokens

Appearance-agnostic fills/borders derived from `.primary`/`.secondary`. Source:
[`Views/DesignSystem.swift`](../Views/DesignSystem.swift).

| Token | Value | Use |
|---|---|---|
| `yankQuietFill` | `.primary` @ 0.04 | Code wells, inline key badges (lowest emphasis) |
| `yankHover` | `.primary` @ 0.05 | Pointer-hover fill |
| `yankSubtleFill` | `.primary` @ 0.06 | Secondary controls, empty-state marks |
| `yankPlaceholderFill` | `.secondary` @ 0.12 | Unloaded-media wash |
| `yankMultiSelect` | `.primary` @ 0.12 | Multi-item selection fill (never the accent hue) |
| `yankSubtleBorder` | `.primary` @ 0.15 | Hairline over media/swatch content |
| `yankMultiSelectSoftBorder` | `.primary` @ 0.18 | Softer multi-select border (compact rows) |
| `yankMultiSelectBorder` | `.primary` @ 0.28 | Neutral selected-state border |
| `yankStrongSwatchBorder` | `.primary` @ 0.85 | Selected swatch ring over arbitrary accent fills |

### Tag palette

Six muted, warm-leaning hues indexed by `tag.hashValue % 6` — identity without a saturated
rainbow. Dark variants are lifted for legibility. **Pill text is `.primary`**, so colour never
carries meaning alone. Source: [`Shared/YankInk.swift`](../Shared/YankInk.swift).

| # | Name | Light | Dark |
|---|---|---|---|
| 0 | dusty blue | `#6B8CC7` | `#8FAEDB` |
| 1 | sage | `#669E80` | `#86C0A0` |
| 2 | clay | `#CC8C4D` | `#DBA46B` |
| 3 | dusty rose | `#BD7885` | `#D296A2` |
| 4 | muted violet | `#8C7DB3` | `#A89DD0` |
| 5 | teal-slate | `#6B999E` | `#8AB8BD` |

---

## Typography

Fixed point sizes on macOS, aligned to native control metrics; iOS maps the same roles to
Dynamic Type. Source: [`Shared/DesignScale.swift`](../Shared/DesignScale.swift) (`TypeScale`).

| Token | pt | Typical use |
|---|---|---|
| `micro` | 10 | Keycaps, eyebrows, tag pills (macOS), badges |
| `caption` | 11 | Quiet metadata, section labels, kind-icon glyphs |
| `control` | 12 | Button text, snug clip body |
| `body` | 13 | Default body / cozy clip text, panel subtitle |
| `input` | 14 | Text fields, airy clip body |
| `title` | 16 | Panel / section titles |
| `stat` | 20 | Stat figures |
| `display` | 24 | Wordmark, display headings |

- **Section label** (`yankSectionLabel`): `caption` (11) semibold, uppercase, kerning `0.6`, `.secondary` — the small Settings headers.
- **Wordmark** ([`Shared/YankWordmark.swift`](../Shared/YankWordmark.swift)): **serif**, semibold — `Yank` in `.primary` + `.` in `.tint`. macOS size = `display` (24).

---

## Spacing & layout

### Space (2pt base grid)

Source: [`Shared/DesignScale.swift`](../Shared/DesignScale.swift) (`Space`).

| Token | pt | | Token | pt |
|---|---|---|---|---|
| `hair`* | 3 | | `lg` | 12 |
| `xxs` | 2 | | `xl` | 16 |
| `xs` | 4 | | `xxl` | 20 |
| `sm` | 6 | | `xxxl` | 24 |
| `md` | 8 | | | |

\* `hair` (3pt) is an off-grid optical nudge for small decorative chrome (pill/keycap/badge padding) only — never structural spacing.

### Radius (applied by role for concentric nesting)

| Token | pt | Role |
|---|---|---|
| `xs` | 4 | Smallest chips — keycaps, badges |
| `sm` | 6 | Inner accents — swatches, thumbnails, kind icons |
| `md` | 9 | Controls — tiles, chips, buttons, clip rows |
| `lg` | 13 | Cards / panels |
| `window` | 18 | The window itself |

Pills use a `Capsule`, not a radius.

### Strokes, icons, hit targets

| Token | Value | Notes |
|---|---|---|
| `Hairline.width` | 0.5 | The one separator / border width (crisp on Retina) |
| `Stroke.focusRing` | 1.5 | Focus ring |
| `IconSize.clipRow` / `emptyState` | 30 | Kind icon in a list row / empty state |
| `ControlTarget.compact` | 24 | macOS pointer target (WCAG 2.5.8 compact min) |
| `ControlTarget.touch` | 44 | iOS touch target (Apple HIG) |

`platformMinimum` resolves to `touch` on iOS, `compact` on macOS — so a shared control reserves the right hit area on each platform even when the glyph draws small.

---

## Motion

Intentionally short timings: Yank is a power-user tool, so motion adds tactility without
slowing keyboard workflows. Every helper returns `nil` under Reduce Motion. Source:
[`Views/DesignSystem.swift`](../Views/DesignSystem.swift) (`YankMotion`) and
[`Shared/DesignScale.swift`](../Shared/DesignScale.swift) (`MotionCurve`, `MotionScale`).

### Curves (shared control points)

| Curve | Control points | Character / use |
|---|---|---|
| `expoOut` | `(0.16, 1, 0.3, 1)` | Decisive, snaps to rest — presents & window summon |
| `quartOut` | `(0.25, 1, 0.5, 1)` | Gentler settle — state changes & hovers |

### Duration tokens

| Helper | Duration | Curve | Use |
|---|---|---|---|
| `instant` | 0.10s | expoOut | Near-immediate feedback |
| `quick` | 0.14s | quartOut | Hover / scale nudges |
| `state` | 0.20s | quartOut | State changes |
| `present` | 0.24s | expoOut | Presentations |
| `navigation` | 0.28s | quartOut | Navigation transitions |
| `shimmer` | 0.9s | easeInOut, repeat | Loading shimmer |

### Specific motions

- **Paste** — scale `1.03`, lift `-2pt`, delay `0.085s`.
- **Capture pulse** (menu-bar glyph on copy) — scale `1.22`, duration `0.34s` (Core Animation).
- **Window summon** (floating history panel) — scale `0.96` (`MotionScale.summon`), in `0.18s` / out `0.12s`, expo-out (Core Animation).

---

## Materials & surfaces

Source: [`Views/DesignSystem.swift`](../Views/DesignSystem.swift).

- **`YankWindowBackground`** — the content canvas: translucent warm vibrancy (`.popover` material) with a `surface @ 0.6` tint on top. Collapses to a solid `yankSurface` under **Reduce Transparency**.
- **Liquid Glass** (`glassControl`, `glassSurface`) — real `glassEffect` on **macOS 26+**, falling back to `.ultraThinMaterial` + a `yankHairline` hairline below 26. Per Apple HIG: glass lives on the floating control layer, never on scrollable content, and never glass-on-glass.

---

## Components

Reusable SwiftUI primitives, shared across macOS and iOS unless noted.

### `IconButton` — [`Views/DesignSystem.swift`](../Views/DesignSystem.swift)
Compact icon-only button with two guarantees the loose `Button { Image }` pattern kept missing: a **required `label`** (never ships without a VoiceOver name) and a **≥24×24pt hit target** (WCAG 2.5.8) regardless of glyph size. `help` defaults to the label, so every button gets a tooltip. Hover → `yankHover` fill + scale `1.04` (`quick` motion), `Radius.sm` corners.

### `TagChip` — [`Shared/TagChip.swift`](../Shared/TagChip.swift)
A tag pill: a 6×6 hue dot for identity, a same-hue wash (fill `0.14`, border `0.28`), and `.primary` text so legibility never depends on the (light) tag colour. Padding `sm`×`xxs`, `Capsule` shape. Optionally tappable (filter) or removable (`xmark`). Hue = `YankInk.tagPalette[hash % 6]`.
**`TagChip.normalize`**: lowercase → collapse whitespace to `-` → trim leading/trailing `-` → cap at 32 chars.

### `ClipStatusBadge` / `RichContentBadge` — [`Shared/ClipStatusBadge.swift`](../Shared/ClipStatusBadge.swift)
- **Status**: `pin.fill` (uses `.tint`) takes precedence over `bookmark.fill` (uses `yankBookmark` gold); nothing renders if neither.
- **Rich content**: `wand.and.stars.inverse` when a formatted archive exists locally; `wand.and.stars` when it was recorded on another device. Both `yankTextTertiary`.

### `ClipKindIcon` — [`Shared/ClipKindIcon.swift`](../Shared/ClipKindIcon.swift)
A 30×30 `Radius.sm` rounded square filled `yankSubtleFill`, with a centred SF Symbol glyph in `.secondary`. The kind glyph itself comes from the clip's `ClipKind` (link / email / phone / code / colour / image / note).

### `YankWordmark` / `YankBrandMark` — [`Shared/YankWordmark.swift`](../Shared/YankWordmark.swift)
Wordmark described under Typography. `YankBrandMark` is the boxed logo: `Radius.md` rounded square, `yankSurface` fill, `yankHairline` border, the `BrandGlyph` asset inset by `size × 0.22`, with a soft `black @ 0.06` shadow.

### `YankPanelTokens` — [`Views/DesignSystem.swift`](../Views/DesignSystem.swift)
AppKit sizing for the native toast/update panels (these draw outside SwiftUI): compact panel `360×214`, corner `Radius.window`, content inset `xxxl`, badge `48×48`, buttons `124/108/82 × 32`, fade in/out `0.22s`/`0.26s`. Fonts map to `TypeScale` (eyebrow `micro` semibold, title `title` semibold, subtitle `body`, detail `caption`, button `control` semibold).

---

## Content-aware layout system

Source: [`Shared/ClipLayout.swift`](../Shared/ClipLayout.swift). The same clips render in any
combination of **view mode × density**; only arrangement changes, so cards morph between modes.

### View modes (`ClipViewMode`)

| Mode | Glyph | Description | Tiled? |
|---|---|---|---|
| list | `list.bullet` | Dense rows — fastest to scan text | no |
| grid | `square.grid.2x2` | Even tiles — lots at a glance | yes |
| masonry | `rectangle.3.offgrid` | Tiles sized to fit — nothing clipped | yes |
| gallery | `square.grid.2x2.fill` | Big rich tiles — best for images | yes |
| split | `rectangle.split.2x1` | A rail plus a live preview pane (macOS only) | no |

### Density (`ClipDensity`) — orthogonal to view mode

| Density | Row v-padding | Row gap | Body font | Excerpt lines | Tile min-width |
|---|---|---|---|---|---|
| snug | 4 | 2 | `control` (12) | 1 | 116 |
| cozy | 8 | 6 | `body` (13) | 2 | 148 |
| airy | 12 | 10 | `input` (14) | 3 | 180 |

### Tile emphasis & lift

`clipRowCornerRadius` = `Radius.md` (9).

| Role | Fill | Border | Width | Shadow |
|---|---|---|---|---|
| focused | 0.10 | 0.90 | `focusRing` (1.5) | 0.07 |
| selected | 0.12 | 0.55 | 1 | 0.05 |
| **lift** raised | — | — | — | scale `1.01`, shadow `0.10`, radius `10`, y `4` |

Lift (pointer hover on macOS / open-item highlight on iPad) combines with an emphasis role without changing layout.

### History limits (`HistoryLimit`)
Essential `100` · Deep `500` · Unlimited `1,000`. Protected clips (pinned / bookmarked / tagged) are always kept regardless of the cap.

---

## Cross-platform notes

- **Shared scales** (`Space`, `Radius`, `TypeScale`, `IconSize`, `Stroke`, `Hairline`, `ControlTarget`, `MotionCurve`, `MotionScale`) compile into both targets from `Shared/`, so they cannot drift.
- **Type**: macOS uses the fixed `TypeScale`; iOS uses Dynamic Type via `IOSType` / `Font.yank(_:)`, so iOS labels grow with the user's text size.
- **Colour bridges**: the `YankInk` pairs are exposed as named `Color`s through an `NSColor` bridge on macOS and a `UIColor` bridge on iOS — identical values, platform-specific plumbing.

## Accessibility

- Foreground inks are AA-verified per appearance, with ratios recorded in the source.
- Colour never carries meaning alone (tag pills label in `.primary`; status uses glyph + label).
- Hit targets meet WCAG 2.5.8 (24pt) on macOS and Apple's 44pt on iOS.
- Reduce Motion disables animation; Reduce Transparency collapses vibrancy to a solid surface.
- Interactive glyphs carry VoiceOver labels and tooltips by construction (`IconButton`).
