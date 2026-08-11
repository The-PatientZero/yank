import SwiftUI

// General section — the broad behaviour toggles: launch at login, menu-bar icon,
// shortcut target, window/picker placement, click-to-paste, haptics, and sound cues.
extension SettingsView {
    var generalSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 0) {
                toggleRow("Launch at login", "Yank starts quietly when you log in.", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { newValue in
                        launchAtLoginError = manager.toggleLaunchAtLogin(newValue)
                    }))
                if let error = launchAtLoginError {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yankDanger)
                            .font(.system(size: TypeScale.caption))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(error)
                                .font(.system(size: TypeScale.micro))
                                .foregroundColor(.yankDanger)
                            Button("Open Login Items →") {
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
                                )
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: TypeScale.micro))
                            .foregroundColor(AppTheme.active.foreground)
                        }
                    }
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.sm)
                }
            }
            Divider().overlay(Color.yankHairline)
            VStack(alignment: .leading, spacing: Space.xs) {
                toggleRow("Show menu bar icon", "The global shortcut still works if it's hidden.", isOn: Binding(
                    get: { manager.showMenuBarIcon },
                    set: { manager.setShowMenuBarIcon($0) }))
                if !manager.showMenuBarIcon {
                    let shortcut = "\(manager.hotkeyModifiers.displayString)\(keyCodeNames[manager.hotkeyKeyCode] ?? "?")"
                    Text("Press \(shortcut) to open Yank, or reopen from Finder to access Settings.")
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(Color.yankHairline)
            field("Shortcut opens", manager.shortcutOpenTarget.blurb) {
                Picker("Shortcut opens", selection: Binding(
                    get: { manager.shortcutOpenTarget },
                    set: { newValue in
                        manager.shortcutOpenTarget = newValue
                        manager.save()
                    })) {
                    ForEach(ShortcutOpenTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 280, alignment: .leading)
                .accessibilityLabel("Shortcut opens")
                .accessibilityValue(manager.shortcutOpenTarget.label)
                .accessibilityHint(manager.shortcutOpenTarget.blurb)
            }
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Keep history window open",
                "Outside clicks leave it visible. Escape and paste still close it.",
                isOn: Binding(
                    get: { manager.keepHistoryWindowOpen },
                    set: { newValue in
                        manager.keepHistoryWindowOpen = newValue
                        manager.save()
                    }))
            Divider().overlay(Color.yankHairline)
            field("Open history at", manager.historyWindowPlacement.blurb) {
                Picker("Open history at", selection: Binding(
                    get: { manager.historyWindowPlacement },
                    set: { newValue in
                        manager.historyWindowPlacement = newValue
                        manager.save()
                    })) {
                    ForEach(HistoryWindowPlacement.allCases) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 340, alignment: .leading)
                .accessibilityLabel("Open history at")
                .accessibilityValue(manager.historyWindowPlacement.label)
                .accessibilityHint(manager.historyWindowPlacement.blurb)
            }
            Divider().overlay(Color.yankHairline)
            field("Open quick picker at", manager.quickPickerPlacement.blurb) {
                Picker("Open quick picker at", selection: Binding(
                    get: { manager.quickPickerPlacement },
                    set: { newValue in
                        manager.quickPickerPlacement = newValue
                        manager.save()
                    })) {
                    ForEach(QuickPickerPlacement.allCases) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 340, alignment: .leading)
                .accessibilityLabel("Open quick picker at")
                .accessibilityValue(manager.quickPickerPlacement.label)
                .accessibilityHint(manager.quickPickerPlacement.blurb)

                if manager.quickPickerPlacement == .focusedInput,
                   let axPermission,
                   !axPermission.isTrusted {
                    quickPickerFieldAccessRow(axPermission)
                }
            }
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Click to paste",
                "List, Grid, Masonry, and Gallery paste immediately. Split previews first.",
                isOn: Binding(
                    get: { manager.clickToPasteInQuickViews },
                    set: { newValue in
                        manager.clickToPasteInQuickViews = newValue
                        manager.save()
                    }))
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Haptic feedback",
                "A subtle tap on copy, paste, and pin. Needs a Force Touch trackpad.",
                isOn: Binding(
                    get: { manager.hapticFeedbackEnabled },
                    set: { newValue in
                        manager.hapticFeedbackEnabled = newValue
                        manager.save()
                        // Let the user feel it the moment they enable it — the toggle is the consent.
                        if newValue { Haptics.fire(.pin, isEnabled: true) }
                    }))
            Divider().overlay(Color.yankHairline)
            soundEffectsSection
        }
    }

    var soundEffectsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            toggleRow(
                "Sound effects",
                "A quiet cue on copy and paste.",
                isOn: Binding(
                    get: { manager.soundEffectsEnabled },
                    set: { newValue in
                        manager.soundEffectsEnabled = newValue
                        manager.save()
                        if newValue { Sounds.preview(manager.soundEffectChoice) }
                    }))
            soundChoiceRow
                .disabled(!manager.soundEffectsEnabled)
                .opacity(manager.soundEffectsEnabled ? 1 : 0.55)
        }
    }

    var soundChoiceRow: some View {
        settingRowControl("Cue style", manager.soundEffectChoice.blurb) {
            HStack(spacing: Space.sm) {
                Picker("Cue style", selection: Binding(
                    get: { manager.soundEffectChoice },
                    set: { newValue in
                        manager.soundEffectChoice = newValue
                        manager.save()
                        if manager.soundEffectsEnabled { Sounds.preview(newValue) }
                    })) {
                    ForEach(SoundEffectChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 104)
                .accessibilityLabel("Cue style")
                .accessibilityValue(manager.soundEffectChoice.label)
                .accessibilityHint(manager.soundEffectChoice.blurb)

                IconButton(
                    systemName: "speaker.wave.2.fill",
                    label: "Preview copy sound",
                    help: "Preview \(manager.soundEffectChoice.label)",
                    tint: AppTheme.active.foreground,
                    size: TypeScale.control,
                    weight: .medium
                ) {
                    Sounds.preview(manager.soundEffectChoice)
                }
            }
        }
    }

    func quickPickerFieldAccessRow(_ axPermission: AccessibilityPermission) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "scope")
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.yankDanger)
            VStack(alignment: .leading, spacing: 1) {
                Text("Accessibility needed to follow the focused field")
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .foregroundColor(.yankDanger)
                Button(AccessibilityPermission.Copy.openSettings) {
                    axPermission.openSettingsAndAwaitGrant()
                }
                .buttonStyle(.plain)
                .font(.system(size: TypeScale.micro))
                .foregroundColor(AppTheme.active.foreground)
            }
        }
    }
}

private extension HistoryWindowPlacement {
    var label: String {
        switch self {
        case .menuBarIcon: "Icon"
        case .lastPosition: "Last"
        case .center: "Center"
        case .topRight: "Top right"
        }
    }

    var blurb: String {
        switch self {
        case .menuBarIcon: "Attach it under the menu bar icon. Falls back to top right when the icon is hidden."
        case .lastPosition: "Reopen where you last moved or resized it."
        case .center: "Open in the center of the active screen."
        case .topRight: "Open near the menu bar on the active screen."
        }
    }
}

private extension QuickPickerPlacement {
    var label: String {
        switch self {
        case .focusedInput: "Field"
        case .menuBarIcon: "Icon"
        case .lastPosition: "Last"
        case .center: "Center"
        case .topRight: "Top right"
        }
    }

    var blurb: String {
        switch self {
        case .focusedInput: "Open beside the focused text field. Falls back to the menu-bar icon when access is unavailable."
        case .menuBarIcon: "Attach it under the menu bar icon. Falls back to top right when the icon is hidden."
        case .lastPosition: "Reopen where you last moved it."
        case .center: "Open in the center of the active screen."
        case .topRight: "Open near the menu bar on the active screen."
        }
    }
}

private extension ShortcutOpenTarget {
    var label: String {
        switch self {
        case .quickPicker: "Quick picker"
        case .fullHistory: "Full history"
        }
    }

    var blurb: String {
        switch self {
        case .quickPicker: "Use the compact chooser for fast paste decisions."
        case .fullHistory: "Open the full organizing window directly."
        }
    }
}

private extension SoundEffectChoice {
    var label: String {
        switch self {
        case .system: "System"
        case .tick: "Tick"
        case .click: "Click"
        case .select: "Select"
        }
    }

    var blurb: String {
        switch self {
        case .system: "The original macOS Tink and Pop."
        case .tick: "Fast and almost invisible."
        case .click: "Crisp, mechanical, and direct."
        case .select: "Rounded and neutral."
        }
    }
}
