import SwiftUI

/// A suggested (on-device AI) tag, visually subordinate to `TagChip` so it reads as a
/// suggestion rather than a user tag. Tapping promotes it to a real tag.
struct AITagChip: View {
    let label: String
    var onPromote: (() -> Void)? = nil

    private var chipFont: Font {
        #if os(iOS)
        .yank(.caption2)
        #else
        .system(size: TypeScale.micro)
        #endif
    }

    var body: some View {
        if let onPromote {
            Button(action: onPromote) { chip }
                .buttonStyle(.plain)
                .frame(minWidth: ControlTarget.platformMinimum, minHeight: ControlTarget.platformMinimum)
                .contentShape(Capsule())
                .help("Add “\(label)” as a tag")
                .accessibilityLabel("Suggested tag \(label)")
                .accessibilityHint("Adds it as a tag")
        } else {
            chip.accessibilityLabel("Suggested tag \(label)")
        }
    }

    private var chip: some View {
        HStack(spacing: Space.xs) {
            Circle()
                .strokeBorder(Color.yankTextTertiary, lineWidth: Hairline.width)
                .frame(width: 6, height: 6)
            Text(label).font(chipFont)
        }
        .foregroundColor(.yankTextTertiary)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xxs)
        .overlay(
            Capsule().strokeBorder(Color.yankHairline,
                                   style: StrokeStyle(lineWidth: Hairline.width, dash: [3, 2]))
        )
        .contentShape(Capsule())
    }
}
