import SwiftUI

struct UndoDeleteBanner: View {
    let message: String
    let onUndo: () -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        #if os(iOS)
        iOSBanner
        #else
        macOSBanner
        #endif
    }

    #if os(iOS)
    private var iOSBanner: some View {
        HStack(spacing: Space.md) {
            Text(message)
                .font(.yank(.subheadline))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", action: onUndo)
                .font(.yank(.subheadline, weight: .semibold))
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(cardBackground)
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.md)
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var cardBackground: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: Radius.md).fill(Color.yankRaised)
        } else {
            RoundedRectangle(cornerRadius: Radius.md).fill(.regularMaterial)
        }
    }
    #else
    private var macOSBanner: some View {
        HStack(spacing: Space.lg) {
            Text(message)
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(.tint)
            Text("⌘Z")
                .font(.system(size: TypeScale.micro, weight: .medium, design: .rounded))
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.hair)
                .background(Color.yankSubtleFill, in: RoundedRectangle(cornerRadius: Radius.xs))
                .foregroundColor(.yankTextTertiary)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.sm)
        .background(Color.yankRaised)
        .overlay(Rectangle().frame(height: Hairline.width).foregroundColor(Color.yankHairline), alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message). Undo with Command Z.")
        .accessibilityAction(named: "Undo", onUndo)
    }
    #endif
}
