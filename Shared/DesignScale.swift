import CoreGraphics

// Numeric scales shared by the macOS and iOS targets. Platform colour bridges
// and view helpers stay in DesignSystem.swift and YankIOSDesignSystem.swift.

// MARK: - Spacing (2pt base grid)

enum Space {
    /// Sub-grid optical nudge (off the 2pt base grid). The breathing room inside small
    /// decorative chrome — pill/keycap/badge padding — where the 2pt grid reads a touch
    /// tight but `Space.xs` (4pt) reads loose. Decorative only; never structural spacing.
    static let hair: CGFloat = 3
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 24
}

// MARK: - Corner radius

/// Radius scale, applied by role for concentric nesting: `window`, `lg` (cards), `md`
/// (controls), `sm` (inner accents), `xs` (small chips). Pills use `Capsule`, not a radius.
enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 9
    static let lg: CGFloat = 13
    static let window: CGFloat = 18
}

// MARK: - Icon sizing

/// Named sizes for the small kind-icons that recur in clip surfaces.
enum IconSize {
    /// The kind icon (swatch / thumbnail / glyph) in a list row.
    static let clipRow: CGFloat = 30
    static let emptyState: CGFloat = 30
}

// MARK: - Stroke widths

enum Stroke {
    static let focusRing: CGFloat = 1.5
}

// MARK: - Motion scales

enum MotionScale {
    static let summon: CGFloat = 0.96
}

// MARK: - Control targets

/// Minimum interactive target sizes. Visual styling stays separate: compact chips
/// and glyphs can draw small while the control still reserves the right hit area.
enum ControlTarget {
    /// Dense macOS pointer target; matches WCAG 2.5.8's compact minimum.
    static let compact: CGFloat = 24

    /// iOS/iPadOS touch target; matches Apple's 44pt HIG expectation.
    static let touch: CGFloat = 44

    /// Platform default for shared controls compiled into both app targets.
    #if os(iOS)
    static let platformMinimum: CGFloat = touch
    #else
    static let platformMinimum: CGFloat = compact
    #endif
}

// MARK: - Hairline

/// The one hairline stroke width used by every ~0.5pt separator and border on both platforms.
/// Renders crisp on Retina; AppKit/UIKit round it to a device pixel.
enum Hairline {
    static let width: CGFloat = 0.5
}

// MARK: - Motion curves

/// Raw control-point tuples for Yank's two easing curves, shared by macOS `YankMotion`,
/// iOS `IOSMotion`, and (on macOS) the Core Animation window summon.
enum MotionCurve {
    /// Expo-out — decisive, snaps to rest. Used for presents and the window summon.
    static let expoOut: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.16, 1, 0.3, 1)
    /// Quart-out — gentler settle. Used for state changes and hovers.
    static let quartOut: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.25, 1, 0.5, 1)
}

// MARK: - Type scale (aligned to native macOS control metrics)

enum TypeScale {
    static let micro: CGFloat = 10
    static let caption: CGFloat = 11
    static let control: CGFloat = 12
    static let body: CGFloat = 13
    static let input: CGFloat = 14
    static let title: CGFloat = 16
    static let stat: CGFloat = 20
    static let display: CGFloat = 24
}
