import SwiftUI

// Appearance leaf controls — accent swatches, view-mode tiles, and density chips.
// `appearanceCard` composes these from `SettingsView`.
extension SettingsView {
    func accentSwatch(_ theme: AppTheme) -> some View {
        Button { setAccent(theme) } label: {
            Circle()
                .fill(theme.color)
                .frame(width: SettingsChipMetrics.accentSwatch, height: SettingsChipMetrics.accentSwatch)
                .overlay(Circle().strokeBorder(Color.yankStrongSwatchBorder,
                                               lineWidth: manager.themeID == theme.id ? 2.5 : 0))
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: TypeScale.caption, weight: .bold))
                    .foregroundColor(theme.onAccent)
                    .opacity(manager.themeID == theme.id ? 0.95 : 0))
                .scaleEffect(manager.themeID == theme.id && !reduceMotion ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(theme.label)
        .accessibilityLabel("\(theme.label) accent")
        .accessibilityValue(manager.themeID == theme.id ? "Selected" : "Not selected")
        .accessibilityHint(manager.themeID == theme.id
            ? "Current accent color."
            : "Sets the accent color to \(theme.label).")
        .accessibilityAddTraits(manager.themeID == theme.id ? .isSelected : [])
        .animation(YankMotion.state(reduceMotion), value: manager.themeID)
    }

    func modeChip(_ mode: ClipViewMode) -> some View {
        let selected = manager.viewMode == mode
        return Button {
            manager.setViewMode(mode)
        } label: {
            SelectionChip(isSelected: selected) {
                VStack(spacing: Space.xs) {
                    Image(systemName: mode.symbol).font(.system(size: TypeScale.body))
                    Text(mode.label).font(.system(size: TypeScale.micro, weight: .medium))
                }
                .frame(width: SettingsChipMetrics.modeTile.width, height: SettingsChipMetrics.modeTile.height)
            }
        }
        .buttonStyle(.plain)
        .help("\(mode.label) — \(mode.blurb)")
        .accessibilityLabel("\(mode.label) view")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected
            ? "Current view mode. \(mode.blurb)"
            : "Switches to \(mode.label) view. \(mode.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func densityChip(_ d: ClipDensity) -> some View {
        let selected = manager.density == d
        return Button {
            manager.setDensity(d)
        } label: {
            SelectionChip(isSelected: selected) {
                Text(d.label)
                    .font(.system(size: TypeScale.control, weight: .medium))
                    .frame(width: SettingsChipMetrics.densityChip.width, height: SettingsChipMetrics.densityChip.height)
            }
        }
        .buttonStyle(.plain)
        .help("\(d.label) — \(d.blurb)")
        .accessibilityLabel("\(d.label) density")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected
            ? "Current density. \(d.blurb)"
            : "Switches to \(d.label) density. \(d.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func setAccent(_ theme: AppTheme) {
        manager.setThemeID(theme.id)
    }
}
