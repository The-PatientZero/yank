import SwiftUI

/// A tag pill: colour dot for identity, `.primary` text so legibility never depends
/// on tag hue. Optionally tappable (filter) or removable (clear the filter).
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

    /// iOS uses Dynamic-Type `.caption2` so tags scale with system text size;
    /// macOS uses a fixed micro size for the compact menu-bar surface.
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

    /// Must match `TagNormalization`'s rule, or the enricher can't tell an AI-suggested
    /// tag is a duplicate of a typed one.
    static func normalize(_ input: String) -> String {
        TagNormalization.normalize(input)
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
