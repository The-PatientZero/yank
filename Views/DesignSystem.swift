import AppKit
import SwiftUI

// The numeric scales (Space / Radius / TypeScale) live in Shared/DesignScale.swift,
// compiled into both the macOS and iOS targets. This file keeps the macOS-only
// colour bridges, view helpers, and reusable styles.

/// Native window vibrancy (macOS "Liquid Glass" material) — used behind the
/// floating panel, warmed by a translucent paper tint on top.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.material = material
    }
}

/// The window's content-layer canvas: translucent warm vibrancy the desktop faintly
/// shows through. When the user turns on Reduce Transparency it collapses to a solid
/// surface — the vibrancy view alone doesn't fully honour that once a translucent
/// tint sits on top. Glass still lives only on the floating controls above this
/// (Apple HIG), never on the content layer.
struct YankWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color.yankSurface
            } else {
                VisualEffectBackground()
                    .overlay(Color.yankSurface.opacity(0.6))
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Color tokens

extension Color {
    /// Resolves to `light` in Aqua, `dark` in Dark Aqua (both packed 0xRRGGBB).
    static func yankDynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(yankRGB: isDark ? dark : light)
        })
    }

    // The warm neutral values live in the shared `YankInk` table (Shared/), so macOS
    // and iOS can't drift; only the NSColor/UIColor bridge differs per platform.
    static let yankSurface = yankDynamic(light: YankInk.surface.light, dark: YankInk.surface.dark)
    static let yankRaised = yankDynamic(light: YankInk.raised.light, dark: YankInk.raised.dark)
    static let yankHairline = yankDynamic(light: YankInk.hairline.light, dark: YankInk.hairline.dark)

    /// Quiet pointer-hover fill — interactive feedback, lighter than any selection.
    static let yankHover = Color.primary.opacity(0.05)
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
    /// Softer multi-select border for compact rows, where the full border reads too heavy.
    static let yankMultiSelectSoftBorder = Color.primary.opacity(0.18)
    /// Neutral selected-state border, paired with `yankMultiSelect`.
    static let yankMultiSelectBorder = Color.primary.opacity(0.28)
    // The semantic inks below come from the shared `YankInk` table, so macOS and iOS
    // expose the identical values. Use `.secondary` for standard labels; reach for
    // `yankTextTertiary` only where small text (10–11pt) was previously dimmed further
    // (it's tuned to ~5:1 so it never dips below AA the way `.secondary` + opacity does).

    /// Bookmark marker (gold), legible as a glyph in both appearances.
    static let yankBookmark = yankDynamic(light: YankInk.bookmark.light, dark: YankInk.bookmark.dark)
    /// "Large" badge background; pairs with white text (AA in both appearances).
    static let yankOversize = yankDynamic(light: YankInk.oversize.light, dark: YankInk.oversize.dark)
    /// Tertiary text — quiet metadata and keyboard hints, AA-safe at small sizes.
    static let yankTextTertiary = yankDynamic(light: YankInk.textTertiary.light, dark: YankInk.textTertiary.dark)
    /// Code / preview body text — a softened but AA-legible ink for monospaced previews and
    /// long-text excerpts, replacing stacked `.primary.opacity(0.8x)` so dark mode stays semantic.
    static let yankCodeText = yankDynamic(light: YankInk.codeText.light, dark: YankInk.codeText.dark)
    /// Destructive / error semantics — a warm-leaning red. Replaces ad-hoc system `.red`.
    static let yankDanger = yankDynamic(light: YankInk.danger.light, dark: YankInk.danger.dark)
    /// Success semantics — verified-update confirmation and similar positive states.
    static let yankSuccess = yankDynamic(light: YankInk.success.light, dark: YankInk.success.dark)
    /// Matched success-badge pair; unlike the foreground success ink, this remains
    /// contrast-safe when one token is drawn directly on the other.
    static let yankSuccessFill = yankDynamic(light: YankInk.successFill.light, dark: YankInk.successFill.dark)
    static let yankOnSuccess = yankDynamic(light: YankInk.onSuccess.light, dark: YankInk.onSuccess.dark)
}

extension NSColor {
    convenience init(yankRGB rgb: Int) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func yankDynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(yankRGB: isDark ? dark : light)
        }
    }

    static var yankSuccess: NSColor { yankDynamic(light: YankInk.success.light, dark: YankInk.success.dark) }
    static var yankSuccessFill: NSColor {
        yankDynamic(light: YankInk.successFill.light, dark: YankInk.successFill.dark)
    }
    static var yankOnSuccess: NSColor {
        yankDynamic(light: YankInk.onSuccess.light, dark: YankInk.onSuccess.dark)
    }
    static var yankTextTertiary: NSColor {
        yankDynamic(light: YankInk.textTertiary.light, dark: YankInk.textTertiary.dark)
    }
    static var yankDanger: NSColor {
        yankDynamic(light: YankInk.danger.light, dark: YankInk.danger.dark)
    }
    static var yankWarning: NSColor {
        yankDynamic(light: YankInk.bookmark.light, dark: YankInk.bookmark.dark)
    }
}

// MARK: - Theme accents

extension AppTheme {
    @MainActor
    static var active: AppTheme {
        from(id: SettingsManager.shared.themeID)
    }

    // `foreground` (the AA-safe accent) lives in Shared/Theme.swift so iOS shares it.

    /// Tinted fill for the focused selection row (accent hue behind primary text).
    var selectionFill: Color {
        color.opacity(0.22)
    }
}

// MARK: - Motion

/// Shared motion tokens for the macOS surface. The timings are intentionally short:
/// Yank is a power-user clipboard tool, so motion should add tactility without making
/// keyboard workflows feel slower.
enum YankMotion {
    static let pasteScale: CGFloat = 1.03
    static let pasteLift: CGFloat = -2
    static let pasteDelay: Double = 0.085

    // Capture pulse — the menu-bar glyph confirms a copy with a quick spring-like scale bounce.
    // Driven at the Core Animation layer in HubController, so these are plain scalars Core
    // Animation consumes directly (a brief overshoot, then settle).
    static let capturePulseScale: CGFloat = 1.22
    static let capturePulseDuration: Double = 0.34

    // Window summon (the floating history panel) — the scale+fade is driven at the AppKit /
    // Core Animation layer in HistoryWindowController, so these are plain scalars Core
    // Animation consumes directly. The curve reuses `expoOutControlPoints` for one language.
    static let summonScale: CGFloat = MotionScale.summon
    static let summonInDuration: Double = 0.18
    static let summonOutDuration: Double = 0.12

    /// Control points for the expo-out curve as `Float`, for the Core Animation window
    /// summon (`CAMediaTimingFunction` needs raw `Float` points). Derived from the shared
    /// `MotionCurve.expoOut` so the SwiftUI and Core Animation summons can't diverge.
    static let expoOutControlPoints: (x1: Float, y1: Float, x2: Float, y2: Float) = {
        let c = MotionCurve.expoOut
        return (Float(c.x1), Float(c.y1), Float(c.x2), Float(c.y2))
    }()

    private static func quartOut(duration: Double) -> Animation {
        let c = MotionCurve.quartOut
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: duration)
    }

    private static func expoOut(duration: Double) -> Animation {
        let c = MotionCurve.expoOut
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: duration)
    }

    static func instant(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : expoOut(duration: 0.10)
    }

    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : quartOut(duration: 0.14)
    }

    static func state(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : quartOut(duration: 0.20)
    }

    static func navigation(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : quartOut(duration: 0.28)
    }

    static func present(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : expoOut(duration: 0.24)
    }

    static func shimmer(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }
}

// MARK: - AppKit panel tokens

enum YankPanelTokens {
    static let compactToastPanelSize = NSSize(width: 360, height: 214)
    static let cornerRadius = Radius.window
    static let contentInset: CGFloat = Space.xxxl
    static let stackSpacing: CGFloat = Space.lg
    static let tightStackSpacing: CGFloat = Space.sm
    static var eyebrowFont: NSFont { NSFont.systemFont(ofSize: TypeScale.micro, weight: .semibold) }
    static var titleFont: NSFont { NSFont.systemFont(ofSize: TypeScale.title, weight: .semibold) }
    static var subtitleFont: NSFont { NSFont.systemFont(ofSize: TypeScale.body) }
    static var detailFont: NSFont { NSFont.systemFont(ofSize: TypeScale.caption) }
    static var buttonFont: NSFont { NSFont.systemFont(ofSize: TypeScale.control, weight: .semibold) }
    static var primaryText: NSColor { .labelColor }
    static var secondaryText: NSColor { .secondaryLabelColor }
    static var tertiaryText: NSColor { .yankTextTertiary }
    static var infoGlyph: NSColor { .controlAccentColor }
    static var successGlyph: NSColor { .yankSuccess }
    static var warningGlyph: NSColor { .yankWarning }
    static var failureGlyph: NSColor { .yankDanger }
    static var badgeFill: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.12) }
    static var detailFill: NSColor { NSColor.textBackgroundColor.withAlphaComponent(0.55) }
    static var panelStroke: NSColor { .separatorColor }
    static let badgeSize = NSSize(width: 48, height: 48)
    static let spinnerSize = NSSize(width: 20, height: 20)
    static let primaryButtonSize = NSSize(width: 124, height: 32)
    static let secondaryButtonSize = NSSize(width: 108, height: 32)
    static let quietButtonSize = NSSize(width: 82, height: 32)
    static let scrollableDetailHeight: CGFloat = 108
    static let symbolPointScale: CGFloat = 0.8
    static let fadeInDuration = 0.22
    static let fadeOutDuration = 0.26
}

// MARK: - Liquid Glass (macOS 26 design language)

/// Per Apple's HIG, Liquid Glass lives on the navigation/control layer that floats
/// above content — never on scrollable content, and never glass directly on glass.
/// The system handles Reduce Transparency / Increase Contrast / Reduce Motion
/// automatically, which is why glass is the language, not a setting. These helpers
/// use the real `glassEffect` on macOS 26+ and fall back to vibrancy below it.
extension View {
    /// A small control cluster on glass (capsule) — e.g. a segmented toggle.
    @ViewBuilder
    func glassControl(interactive: Bool = true) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        }
    }

    /// A floating field / panel / card on glass with concentric corners.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        }
    }
}

// MARK: - Reusable styles

/// A compact icon-only button with two guarantees the loose `Button { Image(...) }`
/// pattern kept getting wrong: a required `label` (so it can never ship without a
/// VoiceOver name) and a hit target that meets WCAG 2.5.8 (≥24×24pt) no matter how
/// small the glyph is drawn. `help` defaults to the label, so every button also
/// gets a tooltip for free.
struct IconButton: View {
    let systemName: String
    let label: String
    var help: String? = nil
    var role: ButtonRole? = nil
    var tint: Color = .secondary
    var size: CGFloat = TypeScale.body
    var weight: Font.Weight = .regular
    var hitTarget: CGFloat = ControlTarget.compact
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .frame(minWidth: hitTarget, minHeight: hitTarget)
                .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .foregroundColor(tint)
        .background(isHovered ? Color.yankHover : Color.clear, in: RoundedRectangle(cornerRadius: Radius.sm))
        .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
        .onHover { isHovered = $0 }
        .animation(YankMotion.quick(reduceMotion), value: isHovered)
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

private struct SectionLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundColor(.secondary)
    }
}

extension View {
    /// Shared treatment for the small uppercase section headers in Settings.
    func yankSectionLabel() -> some View {
        modifier(SectionLabelStyle())
    }
}
