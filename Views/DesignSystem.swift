import AppKit
import SwiftUI

// Space/Radius/TypeScale live in Shared/DesignScale.swift (both targets); this file holds
// macOS-only color bridges, view helpers, and reusable styles.

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

/// Content-layer canvas: warm vibrancy the desktop shows through. Reduce Transparency
/// collapses it to a solid fill — the vibrancy view alone doesn't honor that once a tint
/// sits on top. Never glass here; see the Liquid Glass extension below for why.
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

    // Warm neutral values live in the shared `YankInk` table (Shared/) so macOS/iOS can't drift.
    static let yankSurface = yankDynamic(light: YankInk.surface.light, dark: YankInk.surface.dark)
    static let yankRaised = yankDynamic(light: YankInk.raised.light, dark: YankInk.raised.dark)
    static let yankHairline = yankDynamic(light: YankInk.hairline.light, dark: YankInk.hairline.dark)

    /// Must stay lighter than any selection fill.
    static let yankHover = Color.primary.opacity(0.05)
    static let yankQuietFill = Color.primary.opacity(0.04)
    static let yankSubtleFill = Color.primary.opacity(0.06)
    static let yankPlaceholderFill = Color.secondary.opacity(0.12)
    /// Hairline on top of media/swatch content where the normal separator is too quiet.
    static let yankSubtleBorder = Color.primary.opacity(0.15)
    /// Strong neutral ring for selected swatches that must read on arbitrary accent fills.
    static let yankStrongSwatchBorder = Color.primary.opacity(0.85)
    /// Neutral fill for a multi-item selection — never collides with the accent hue.
    static let yankMultiSelect = Color.primary.opacity(0.12)
    /// Softer multi-select border for compact rows, where the full border reads too heavy.
    static let yankMultiSelectSoftBorder = Color.primary.opacity(0.18)
    static let yankMultiSelectBorder = Color.primary.opacity(0.28)
    // Use `.secondary` for standard labels; reach for `yankTextTertiary` only for small text
    // that needs to stay AA-safe (see its doc comment).

    /// Bookmark marker (gold), legible as a glyph in both appearances.
    static let yankBookmark = yankDynamic(light: YankInk.bookmark.light, dark: YankInk.bookmark.dark)
    /// "Large" badge background; pairs with white text (AA in both appearances).
    static let yankOversize = yankDynamic(light: YankInk.oversize.light, dark: YankInk.oversize.dark)
    /// Tertiary text for quiet metadata/keyboard hints — tuned to ~5:1 contrast so small text
    /// (10–11pt) stays AA-safe, unlike `.secondary` + opacity.
    static let yankTextTertiary = yankDynamic(light: YankInk.textTertiary.light, dark: YankInk.textTertiary.dark)
    /// Code / preview body text — AA-legible ink for monospaced previews and long excerpts;
    /// kept semantic (not `.primary` + opacity) so dark mode contrast holds.
    static let yankCodeText = yankDynamic(light: YankInk.codeText.light, dark: YankInk.codeText.dark)
    static let yankDanger = yankDynamic(light: YankInk.danger.light, dark: YankInk.danger.dark)
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

/// Shared motion tokens for the macOS surface, intentionally short: Yank is a power-user
/// tool, so motion adds tactility without slowing keyboard workflows.
enum YankMotion {
    static let pasteScale: CGFloat = 1.03
    static let pasteLift: CGFloat = -2
    static let pasteDelay: Double = 0.085

    // Capture pulse (menu-bar glyph copy confirmation) is driven at the Core Animation layer
    // in HubController — these are plain scalars CA consumes directly, not a SwiftUI animation.
    static let capturePulseScale: CGFloat = 1.22
    static let capturePulseDuration: Double = 0.34

    // Window summon (floating history panel) — driven at the AppKit/Core Animation layer in
    // HistoryWindowController; same plain-scalar reasoning as the capture pulse above. Curve
    // reuses `expoOutControlPoints` for one shared language.
    static let summonScale: CGFloat = MotionScale.summon
    static let summonInDuration: Double = 0.18
    static let summonOutDuration: Double = 0.12

    /// Expo-out curve control points as `Float` — `CAMediaTimingFunction` requires raw `Float`.
    /// Derived from `MotionCurve.expoOut` so SwiftUI and Core Animation summons can't diverge.
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

/// Liquid Glass (HIG): lives only on the floating nav/control layer, never on scrollable
/// content or stacked glass-on-glass. Reduce Transparency/Contrast/Motion are handled by
/// the system automatically. Uses real `glassEffect` on macOS 26+, vibrancy fallback below.
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

/// Icon-only button with two guarantees ad-hoc `Button { Image(...) }` calls miss: a
/// required `label` (VoiceOver name) and a hit target meeting WCAG 2.5.8 (≥24×24pt).
/// `help` defaults to `label`, so every button gets a tooltip for free.
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
