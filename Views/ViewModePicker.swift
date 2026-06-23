import SwiftUI

/// The segmented List / Grid / Masonry / Gallery / Split toggle in the history header.
/// Persists the choice to `SettingsManager` and animates the bound `selection`.
struct ViewModePicker: View {
    @Binding var selection: ClipViewMode
    var reduceMotion: Bool

    @Namespace private var selectionIndicator

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(ClipViewMode.platformCases) { mode in
                Button { select(mode) } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: TypeScale.control, weight: .medium))
                        .frame(width: 28, height: 24)
                        .foregroundColor(selection == mode ? AppTheme.active.foreground : .secondary)
                        .background(selectionFill(for: mode))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(selection == mode ? AppTheme.active.foreground.opacity(0.35) : Color.clear,
                                              lineWidth: Hairline.width)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(mode.label) — \(mode.blurb)")
                .accessibilityLabel("\(mode.label) view")
                .accessibilityValue(selection == mode ? "Selected" : "Not selected")
                .accessibilityHint(selection == mode
                    ? "Current view mode. \(mode.blurb)"
                    : "Switches to \(mode.label) view. \(mode.blurb)")
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(Space.hair)
        .glassControl()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
        .animation(YankMotion.state(reduceMotion), value: selection)
    }

    @ViewBuilder
    private func selectionFill(for mode: ClipViewMode) -> some View {
        if selection == mode {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(AppTheme.active.selectionFill)
                .matchedGeometryEffect(id: "view-mode-selection", in: selectionIndicator)
        }
    }

    private func select(_ mode: ClipViewMode) {
        guard mode != selection else { return }
        SettingsManager.shared.viewMode = mode
        SettingsManager.shared.save()
        withAnimation(YankMotion.navigation(reduceMotion)) {
            selection = mode
        }
    }
}
