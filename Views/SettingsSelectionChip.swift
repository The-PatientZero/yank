import SwiftUI

private enum SelectionChipStyle {
    static let cornerRadius = Radius.md
}

/// The one selection-chip surface for Settings: every selected option shares the
/// same rounded-rectangle radius, accent fill, and selected border. Mode, Density,
/// and (history) Tier all compose this so their outlines cannot drift again. The
/// accent hue is never the only "chosen" signal: this draws a corner checkmark cue
/// by default (Tier opts out because it carries its own filled-radio glyph). Meets
/// WCAG 1.4.11: the selected border is well above 3:1 and the cue is non-colour.
struct SelectionChip<Content: View>: View {
    let isSelected: Bool
    /// Draw the corner checkmark cue (the non-colour selected signal).
    var showsCheckmarkCue: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var selectedScale: CGFloat { 1.02 }

    var body: some View {
        content()
            .foregroundColor(isSelected ? AppTheme.active.foreground : .secondary)
            .background(fill)
            .overlay(border)
            .overlay(alignment: .topTrailing) {
                if showsCheckmarkCue && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: TypeScale.caption, weight: .bold))
                        .foregroundColor(AppTheme.active.foreground)
                        .padding(Space.xs)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isSelected && !reduceMotion ? Self.selectedScale : 1)
            .animation(YankMotion.state(reduceMotion), value: isSelected)
    }

    @ViewBuilder private var fill: some View {
        let color = isSelected ? AppTheme.active.selectionFill : Color.yankSurface
        color.clipShape(RoundedRectangle(cornerRadius: SelectionChipStyle.cornerRadius))
    }

    @ViewBuilder private var border: some View {
        let width: CGFloat = isSelected ? 2.5 : Hairline.width
        let stroke = isSelected ? AppTheme.active.foreground : Color.yankHairline
        RoundedRectangle(cornerRadius: SelectionChipStyle.cornerRadius).strokeBorder(stroke, lineWidth: width)
    }
}
