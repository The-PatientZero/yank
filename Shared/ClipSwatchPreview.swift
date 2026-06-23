import SwiftUI

struct ClipSwatchPreview: View {
    let color: Color
    let raw: String
    var cornerRadius: CGFloat = Radius.sm

    private var labelFont: Font {
        #if os(iOS)
        .system(.caption, design: .monospaced).weight(.medium)
        #else
        .system(size: TypeScale.caption, weight: .medium, design: .monospaced)
        #endif
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.yankMultiSelect, lineWidth: Hairline.width)
            )
            .overlay(alignment: .bottomLeading) {
                Text(raw.uppercased())
                    .font(labelFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.hair)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(Space.sm)
            }
    }
}
