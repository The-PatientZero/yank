import SwiftUI

struct YankWordmark: View {
    #if os(iOS)
    var size: CGFloat = IOSType.wordmark
    #else
    var size: CGFloat = TypeScale.display
    #endif

    var body: some View {
        HStack(spacing: 0) {
            Text("Yank").foregroundStyle(.primary)
            Text(".").foregroundStyle(.tint)
        }
        .font(.system(size: size, weight: .semibold, design: .serif))
        .accessibilityElement()
        .accessibilityLabel("Yank")
    }
}

struct YankBrandMark: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Color.yankSurface)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Color.yankHairline, lineWidth: Hairline.width)
            )
            .overlay {
                Image("BrandGlyph")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.06), radius: 5, y: 1)
            .accessibilityElement()
            .accessibilityLabel("Yank logo")
    }
}
