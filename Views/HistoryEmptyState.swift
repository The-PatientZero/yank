import SwiftUI

/// The empty-state card for the history stream — distinguishes a genuinely empty
/// clipboard (`isClear`) from a search/filter that matched nothing.
struct HistoryEmptyState: View {
    var isClear: Bool
    var settings: SettingsManager = .shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var hotkeyDisplay: String {
        let key = keyCodeNames[settings.hotkeyKeyCode] ?? "V"
        return settings.hotkeyModifiers.displayString + key
    }

    var body: some View {
        VStack(spacing: Space.md) {
            Image("BrandGlyph")
                .renderingMode(.template)
                .resizable()
                .frame(width: IconSize.emptyState, height: IconSize.emptyState)
                .foregroundColor(.secondary.opacity(0.35))
                .accessibilityHidden(true)
            Text(isClear ? "Your clipboard is clear" : "No matches")
                .font(.system(size: TypeScale.input, weight: .semibold, design: .serif))
                .foregroundColor(.secondary)
            if isClear {
                Text("Copy anything — it lands here, quietly.")
                    .font(.system(size: TypeScale.caption))
                    .foregroundColor(.yankTextTertiary)
                Text("Press \(hotkeyDisplay) from any app")
                    .font(.system(size: TypeScale.caption))
                    .foregroundColor(.yankTextTertiary)
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.xxxl)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : YankMotion.summonScale))
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(YankMotion.present(reduceMotion)) { appeared = true }
            }
        }
    }
}

/// A skeleton shown on a cold open while the store hydrates from disk — so a large,
/// populated history never momentarily reads as "clear". A few redacted stub rows
/// that shimmer (Reduce Motion stills them), mirroring the List row's geometry.
struct HistoryLoadingState: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    private let rowCount = 4

    var body: some View {
        VStack(spacing: Space.sm) {
            ForEach(0..<rowCount, id: \.self) { _ in
                stubRow
            }
        }
        .redacted(reason: .placeholder)
        .opacity(reduceMotion ? 1 : (shimmer ? 0.5 : 1))
        .animation(YankMotion.shimmer(reduceMotion), value: shimmer)
        .onAppear { shimmer = true }
        .accessibilityElement()
        .accessibilityLabel("Loading clips")
    }

    private var stubRow: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.yankSubtleFill)
                .frame(width: IconSize.clipRow, height: IconSize.clipRow)
            VStack(alignment: .leading, spacing: Space.xs) {
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(Color.yankSubtleFill)
                    .frame(height: TypeScale.body)
                    .frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(Color.yankSubtleFill)
                    .frame(width: 120, height: TypeScale.micro)
            }
            Spacer(minLength: Space.sm)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.yankHairline, lineWidth: Hairline.width)
        )
    }
}
