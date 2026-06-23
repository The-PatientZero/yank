import SwiftUI

struct ClipKindIcon: View {
    let glyph: String

    private static let fill = Color.yankSubtleFill

    private var glyphFont: Font {
        #if os(iOS)
        .yank(.subheadline)
        #else
        .system(size: TypeScale.caption)
        #endif
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sm)
            .fill(Self.fill)
            .frame(width: IconSize.clipRow, height: IconSize.clipRow)
            .overlay(
                Image(systemName: glyph)
                    .font(glyphFont)
                    .foregroundStyle(.secondary)
            )
    }
}
