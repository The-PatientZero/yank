import SwiftUI

/// A tag pill: a hue dot for identity, a subtle same-hue wash, and `.primary`
/// text so legibility never depends on the (light) tag color. Optionally tappable
/// (filter by tag) or removable (clear the active filter).
struct TagChip: View {
    private enum Metrics {
        static let fillOpacity = 0.14
        static let borderOpacity = 0.28
    }

    let label: String
    var displayPrefix: String = ""
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    private var hue: Color { TagChip.color(for: label) }

    /// The pill type: the Dynamic-Type `.caption2` style on iOS (so tags grow with the
    /// user's text size like every other iOS label), and the fixed micro size on the
    /// compact macOS menu-bar surface, matching each platform's ramp.
    private var chipFont: Font {
        #if os(iOS)
        .yank(.caption2)
        #else
        .system(size: TypeScale.micro)
        #endif
    }

    static func color(for tag: String) -> Color {
        let index = YankInk.tagPaletteIndex(for: tag)
        let pair = YankInk.tagPalette[index]
        return .yankDynamic(light: pair.light, dark: pair.dark)
    }

    static func normalize(_ input: String) -> String {
        let lower = input.lowercased()
        let dashed = lower.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        let trimmed = dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(32))
    }

    var body: some View {
        if let onRemove = onRemove {
            Button(action: onRemove) {
                chipBody(showsRemoveGlyph: true)
            }
            .buttonStyle(.plain)
            .frame(minWidth: ControlTarget.platformMinimum, minHeight: ControlTarget.platformMinimum)
            .contentShape(Capsule())
            .accessibilityLabel("Remove \(displayTitle)")
            .help("Remove \(displayTitle)")
        } else if let onTap = onTap {
            Button(action: onTap) {
                chipBody(showsRemoveGlyph: false)
            }
            .buttonStyle(.plain)
            .frame(minWidth: ControlTarget.platformMinimum, minHeight: ControlTarget.platformMinimum)
            .contentShape(Capsule())
            .accessibilityLabel(displayTitle)
            .accessibilityHint("Filter by this tag")
        } else {
            chipBody(showsRemoveGlyph: false)
        }
    }

    private var displayTitle: String { displayPrefix + label }

    private func chipBody(showsRemoveGlyph: Bool) -> some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(hue)
                .frame(width: 6, height: 6)
            labelText
            if showsRemoveGlyph {
                Image(systemName: "xmark")
                    .font(chipFont.weight(.bold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xxs)
        .background(hue.opacity(Metrics.fillOpacity), in: Capsule())
        .overlay(Capsule().strokeBorder(hue.opacity(Metrics.borderOpacity), lineWidth: Hairline.width))
        .contentShape(Capsule())
    }

    private var labelText: some View {
        Text(displayTitle)
            .font(chipFont)
            .foregroundColor(.primary)
    }
}
