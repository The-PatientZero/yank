import Foundation

/// Yank's ink table — every brand colour as packed `0xRRGGBB` `(light, dark)` pairs, in
/// one place so the platform colour bridges (`NSColor` on macOS, `UIColor` on iOS) can't
/// drift. The bridges read these pairs and expose them as named `Color`s; the saturated
/// accent *fills* live in `Theme.swift` (`AppTheme.color`) and its AA-safe foregrounds in
/// the same file. Neutrals plus the semantic inks below cover everything else.
enum YankInk {
    // MARK: Neutral "paper" surfaces

    /// Warm base surface (window / list background).
    static let surface = (light: 0xF6F2EC, dark: 0x1A1916)
    /// Warm raised surface (bars, inputs, cards) — barely lifted from the base.
    static let raised = (light: 0xFCF9F4, dark: 0x232220)
    /// Warm hairline separator — replaces hard system dividers.
    static let hairline = (light: 0xE7E0D5, dark: 0x33302B)

    // MARK: Semantic ink (appearance pairs the bridges expose as named Colors)

    /// Bookmark marker (gold), legible as a glyph in both appearances. The light value
    /// is tuned to clear WCAG 2.2 1.4.11 (≥3:1 non-text) on the paper/raised surfaces at
    /// full opacity — 4.05:1 on surface, 4.3:1 on raised — so the glyph never depends on
    /// stacked `.opacity` to be perceivable.
    static let bookmark = (light: 0x9A6F08, dark: 0xFFCC4D)
    /// Bookmark as a *fill* behind a white glyph (the iOS swipe action), distinct from the
    /// on-paper `bookmark` glyph above: white on #FFCC4D is only 1.5:1, so the fill takes a
    /// darker goldenrod that gives white 5.38:1. The pair is intentionally identical — the
    /// fill is drawn behind white regardless of the app surface, so it doesn't adapt.
    static let bookmarkFill = (light: 0x8A6400, dark: 0x8A6400)
    /// Tertiary text — quiet metadata and hints tuned to clear WCAG-AA (~5:1) on the
    /// paper/raised surfaces, so small labels never depend on stacked `.opacity`.
    static let textTertiary = (light: 0x6E665A, dark: 0x9C948A)
    /// Code / preview body text — a softened but still high-contrast ink for monospaced
    /// previews and long-text excerpts. Sits one step above `textTertiary` (it carries
    /// the full content, not metadata): a warm secondary weight that clears AA comfortably
    /// (~8:1 light, ~7:1 dark) so it stays legible as body/code text without the stacked
    /// `.primary.opacity(0.8x)` that wasn't contrast-verified per appearance.
    static let codeText = (light: 0x4A453E, dark: 0xC4BCB2)
    /// Destructive / error semantics — a warm-leaning red, AA-legible as a foreground.
    static let danger = (light: 0xC2371F, dark: 0xFF6B5A)
    /// Success semantics — used for positive status glyphs and confirmations.
    static let success = (light: 0x2F855A, dark: 0x48BB78)
    /// "Large" badge background; pairs with white text at full opacity (5.02:1 light,
    /// 5.18:1 dark — both clear AA for small text). The dark variant is lifted a touch
    /// so the badge sits warmer on the dark surface instead of reading as a flat block.
    static let oversize = (light: 0xB45309, dark: 0xC2410C)

    /// Tag-pill hues — a muted, warm-leaning palette indexed by the tag's hash (identity
    /// without a saturated rainbow). Dark variants are lifted so the dot + wash stay legible
    /// on the dark surface. Pill text is `.primary`, so colour never carries meaning alone.
    static let tagPalette: [(light: Int, dark: Int)] = [
        (light: 0x6B8CC7, dark: 0x8FAEDB), // dusty blue
        (light: 0x669E80, dark: 0x86C0A0), // sage
        (light: 0xCC8C4D, dark: 0xDBA46B), // clay
        (light: 0xBD7885, dark: 0xD296A2), // dusty rose
        (light: 0x8C7DB3, dark: 0xA89DD0), // muted violet
        (light: 0x6B999E, dark: 0x8AB8BD) // teal-slate
    ]
}
