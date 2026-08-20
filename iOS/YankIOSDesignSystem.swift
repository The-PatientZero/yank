import SwiftUI
import UIKit

// The Space / Radius / TypeScale scales live in Shared/DesignScale.swift, compiled
// into both the macOS and iOS targets. This file keeps the iOS-only colour bridges,
// the Dynamic-Type font ramp, and iOS metrics.

enum IOSMetric {
    static let emptyIconSize: CGFloat = 38
    static let unlockIconSize: CGFloat = 52
}

/// iOS font sizes that sit a step above the stock Dynamic-Type styles, for the two
/// surfaces that read better a touch larger: clip content and the nav-bar wordmark.
enum IOSType {
    /// Clip content (list rows, detail). Used as the base for `@ScaledMetric` so it
    /// still grows with the user's preferred text size; +2 over the 17pt system body.
    static let readingBody: CGFloat = 19
    /// The nav-bar wordmark — a touch above the shared 16pt `TypeScale.title`.
    static let wordmark: CGFloat = 18
}

extension Font {
    /// The iOS type ramp: a Dynamic-Type text style with an optional weight. Anchoring to text
    /// styles (not the fixed-point `TypeScale` macOS draws with) lets every label scale with the
    /// user's preferred content size (WCAG 1.4.4); macOS keeps the fixed scale as idiomatic for a compact utility.
    static func yank(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style).weight(weight)
    }
}

extension Color {
    static func yankDynamic(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(yankRGB: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    // Neutral + semantic values come from the shared `YankInk` table (Shared/) — see
    // macOS twin. Both platforms read the identical pairs, so the brand can't drift.
    static let yankSurface = yankDynamic(light: YankInk.surface.light, dark: YankInk.surface.dark)
    static let yankRaised = yankDynamic(light: YankInk.raised.light, dark: YankInk.raised.dark)
    static let yankHairline = yankDynamic(light: YankInk.hairline.light, dark: YankInk.hairline.dark)
    /// Lowest-emphasis neutral fill, used for code wells and inline key badges.
    static let yankQuietFill = Color.primary.opacity(0.04)
    /// Soft neutral fill for secondary controls and empty-state marks.
    static let yankSubtleFill = Color.primary.opacity(0.06)
    /// Placeholder wash for unloaded media.
    static let yankPlaceholderFill = Color.secondary.opacity(0.12)
    /// Hairline on top of media/swatch content where the normal separator is too quiet.
    static let yankSubtleBorder = Color.primary.opacity(0.15)
    /// Strong neutral ring for selected swatches that must read on arbitrary accent fills.
    static let yankStrongSwatchBorder = Color.primary.opacity(0.85)
    /// Neutral fill for a multi-item selection — never collides with the accent hue.
    static let yankMultiSelect = Color.primary.opacity(0.12)
    /// Neutral selected-state border, paired with `yankMultiSelect`.
    static let yankMultiSelectBorder = Color.primary.opacity(0.28)

    /// Bookmark marker (gold) — matches the Mac instead of falling back to system orange.
    static let yankBookmark = yankDynamic(light: YankInk.bookmark.light, dark: YankInk.bookmark.dark)
    /// Bookmark as a swipe-action fill (white glyph on gold) — darker than the on-paper
    /// glyph so white clears AA (5.38:1) rather than the 1.5:1 the lighter glyph gold gives.
    static let yankBookmarkFill = yankDynamic(light: YankInk.bookmarkFill.light, dark: YankInk.bookmarkFill.dark)
    /// Tertiary text — quiet metadata tuned to ~5:1, so small labels stay AA-legible
    /// instead of using system `.tertiary` (which isn't contrast-verified on paper).
    static let yankTextTertiary = yankDynamic(light: YankInk.textTertiary.light, dark: YankInk.textTertiary.dark)
    /// Code / preview body text — a softened but AA-legible ink for monospaced previews and
    /// long-text excerpts, replacing stacked `.primary.opacity(0.8x)` so dark mode stays semantic.
    static let yankCodeText = yankDynamic(light: YankInk.codeText.light, dark: YankInk.codeText.dark)
    /// Destructive / error semantics — the warm-leaning brand red, shared with the Mac so
    /// iOS destructive actions read as Yank instead of falling back to system `.red`.
    static let yankDanger = yankDynamic(light: YankInk.danger.light, dark: YankInk.danger.dark)
    /// "Large" badge background; pairs with white text (AA in both appearances). Shared
    /// with the Mac so the oversize marker carries the same warm brand intent on iOS.
    static let yankOversize = yankDynamic(light: YankInk.oversize.light, dark: YankInk.oversize.dark)
    static let yankSuccess = yankDynamic(light: YankInk.success.light, dark: YankInk.success.dark)
    /// Matched success-badge pair for small text and glyphs on a success fill.
    static let yankSuccessFill = yankDynamic(light: YankInk.successFill.light, dark: YankInk.successFill.dark)
    static let yankOnSuccess = yankDynamic(light: YankInk.onSuccess.light, dark: YankInk.onSuccess.dark)
}

// MARK: - Motion

/// Shared motion tokens for iOS/iPadOS. Keep them shorter than marketing-style
/// motion: Yank is a utility, so tactility should make actions feel confirmed,
/// not make the user wait for decoration to finish.
enum IOSMotion {
    static let cardScale: CGFloat = 0.992

    private static func quartOut(duration: Double) -> Animation {
        let c = MotionCurve.quartOut
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: duration)
    }

    private static func expoOut(duration: Double) -> Animation {
        let c = MotionCurve.expoOut
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: duration)
    }

    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : quartOut(duration: 0.14)
    }

    static func state(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : quartOut(duration: 0.22)
    }

    static func present(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : expoOut(duration: 0.26)
    }

    @MainActor
    private static let selectionGenerator: UISelectionFeedbackGenerator = {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        return g
    }()

    @MainActor
    static func selectionFeedback() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    @MainActor
    static func successFeedback() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private extension UIColor {
    convenience init(yankRGB rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
