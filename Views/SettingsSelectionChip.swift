import SwiftUI

private enum SelectionChipStyle {
    static let cornerRadius = Radius.md
}

/// The one selection-chip surface for Settings (Mode, Density, Tier) so their outlines can't drift.
/// WCAG 1.4.11: selection is never colour-only — draws a non-colour checkmark cue by default (Tier
/// opts out; it has its own filled-radio glyph) and keeps the selected border ≥3:1 contrast.
struct SelectionChip<Content: View>: View {
    let isSelected: Bool
    /// Set false when the caller already shows its own non-colour selected cue (e.g. Tier's radio glyph).
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
