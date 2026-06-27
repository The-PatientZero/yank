import SwiftUI

// Shortcut card section — the live recorder field, helper/conflict copy, and preset buttons.
extension SettingsView {
    var showsHotkeyFailure: Bool {
        appStatus?.hotkeyRegistrationFailed == true
    }

    var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    Text(manager.hotkeyModifiers.displayString)
                        .font(.system(size: TypeScale.input, weight: .medium, design: .monospaced))
                    Text(keyCodeNames[manager.hotkeyKeyCode] ?? "?")
                        .font(.system(size: TypeScale.input, weight: .medium, design: .monospaced))
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(RoundedRectangle(cornerRadius: Radius.md)
                    .fill(isRecording ? AppTheme.active.selectionFill : Color.yankSurface))
                .overlay(RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(isRecording ? AppTheme.active.foreground : Color.yankHairline,
                            lineWidth: isRecording ? Stroke.focusRing : Hairline.width))
                .scaleEffect(isRecording && !reduceMotion ? 1.015 : 1)
                .animation(YankMotion.state(reduceMotion), value: isRecording)
                .accessibilityLabel("Current shortcut")
                .accessibilityValue(shortcutAccessibilityValue)

                Button(action: {
                    isRecording.toggle()
                    // Reset the conflict whether we're arming a fresh capture or cancelling.
                    shortcutConflict = nil
                }) {
                    Text(isRecording ? "Cancel" : "Change")
                        .font(.system(size: TypeScale.control, weight: .medium))
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            Text(shortcutHelperText)
                .font(.system(size: TypeScale.micro))
                .foregroundColor(shortcutConflict != nil ? .yankDanger
                                 : (isRecording ? AppTheme.active.foreground : .yankTextTertiary))

            if showsHotkeyFailure {
                Label("Shortcut registration failed — may conflict with another app.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(.yankDanger)
            }

            adaptiveGrid(minimum: 64) {
                presetButton(label: "⇧⌘V", humanLabel: "Shift Command V",
                             mods: HotkeyModifiers(shift: true, command: true), keyCode: 9)
                presetButton(label: "⌥⌘V", humanLabel: "Option Command V",
                             mods: HotkeyModifiers(command: true, option: true), keyCode: 9)
                presetButton(label: "⌃⇧V", humanLabel: "Control Shift V",
                             mods: HotkeyModifiers(shift: true, control: true), keyCode: 9)
                presetButton(label: "⌘B", humanLabel: "Command B",
                             mods: HotkeyModifiers(command: true), keyCode: 11)
            }
        }
    }

    /// Helper line under the shortcut field: the conflict reason wins, then the
    /// recording prompt, then the resting explanation.
    var shortcutHelperText: String {
        if let conflict = shortcutConflict {
            return "\(conflict) is reserved by macOS. Try another shortcut."
        }
        return isRecording ? "Press your new shortcut…" : "The global shortcut opens Yank from any app."
    }

    var shortcutAccessibilityValue: String {
        let combo = "\(manager.hotkeyModifiers.displayString)\(keyCodeNames[manager.hotkeyKeyCode] ?? "?")"
        if let conflict = shortcutConflict {
            return "\(combo). \(conflict) is reserved by macOS — try another shortcut."
        }
        return combo
    }

    func presetButton(label: String, humanLabel: String, mods: HotkeyModifiers, keyCode: UInt16) -> some View {
        let isActive = manager.hotkeyModifiers == mods && manager.hotkeyKeyCode == keyCode
        return Button(action: {
            manager.setHotkey(keyCode: keyCode, modifiers: mods)
        }) {
            Text(label)
                .font(.system(size: TypeScale.control, weight: .medium, design: .monospaced))
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(humanLabel) shortcut preset")
        .accessibilityValue(isActive ? "Current shortcut" : "")
        .accessibilityHint("Sets the global shortcut to \(humanLabel).")
    }
}
