import SwiftUI

struct StorageUnavailableBanner: View {
    private static let message = "Storage unavailable — clips won't be saved this session."

    private var labelFont: Font {
        #if os(iOS)
        .yank(.footnote)
        #else
        .system(size: TypeScale.caption)
        #endif
    }

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(labelFont.weight(.semibold))
                .foregroundColor(.yankDanger)
                .accessibilityHidden(true)
            Text(Self.message)
                .font(labelFont)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.sm)
        .background(Color.yankDanger.opacity(0.10))
        .overlay(
            Rectangle().frame(height: Hairline.width).foregroundColor(Color.yankDanger.opacity(0.25)),
            alignment: .bottom
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(Self.message)")
    }
}
