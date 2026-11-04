import SwiftUI

struct FooterHintsBar: View {
    var selectionCount: Int
    var clickToPaste: Bool = false
    var hasPendingUndo: Bool = false
    var focusedItemHasOCR: Bool = false
    var quickLookAvailable: Bool = true
    var axUntrusted: Bool = false
    /// Runs the shared grant flow. Injected so the footer drives the same shared permission object
    /// Settings uses (one source of truth); required so the button can never be a silent no-op.
    let onGrantAccess: () -> Void

    var body: some View {
        HStack(spacing: Space.lg) {
            if selectionCount > 1 {
                keyHint("↵", axUntrusted ? "copy \(selectionCount)" : "paste \(selectionCount)")
                keyHint("⌘C", "copy \(selectionCount)")
                Spacer()
                if axUntrusted {
                    Text(AccessibilityPermission.Copy.accessNeeded)
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankDanger)
                    Button(AccessibilityPermission.Copy.openSettings) { onGrantAccess() }
                        .buttonStyle(.plain)
                        .font(.system(size: TypeScale.micro, weight: .semibold))
                        .foregroundColor(AppTheme.active.foreground)
                        .accessibilityHint("Opens System Settings to grant Accessibility access.")
                } else {
                    keyHint("esc", "deselect")
                    keyHint("⌘⌫", "delete")
                }
            } else {
                if axUntrusted {
                    keyHint(clickToPaste ? "click" : "↵", "copy")
                    Spacer()
                    Text(AccessibilityPermission.Copy.accessNeeded)
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankDanger)
                    Button(AccessibilityPermission.Copy.openSettings) { onGrantAccess() }
                        .buttonStyle(.plain)
                        .font(.system(size: TypeScale.micro, weight: .semibold))
                        .foregroundColor(AppTheme.active.foreground)
                        .accessibilityHint("Opens System Settings to grant Accessibility access.")
                } else {
                    // Narrow windows drop hints in `SingleHint.dropOrder`; the first tier that fits wins.
                    ViewThatFits(in: .horizontal) {
                        ForEach(0...SingleHint.dropOrder.count, id: \.self) { dropped in
                            singleSelectionHints(dropping: dropped)
                        }
                    }
                }
            }
        }
        .font(.system(size: TypeScale.micro))
        .foregroundColor(.yankTextTertiary)
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.sm)
        .overlay(Rectangle().frame(height: Hairline.width).foregroundColor(Color.yankHairline), alignment: .top)
        .accessibilityElement()
        .accessibilityLabel(footerAccessibilityLabel)
        .accessibilityHidden(false)
        .accessibilityAction(named: "Grant Accessibility access") {
            if axUntrusted { onGrantAccess() }
        }
    }

    /// Single-selection hints that give way, first to last, when the footer is too narrow.
    /// "↵ paste", "⌘C copy" and "⌘⌫ delete" (or "⌘Z undo delete") never drop.
    private enum SingleHint {
        case settings, layout, peek, instant, clickPaste

        static let dropOrder: [SingleHint] = [.settings, .layout, .peek, .instant, .clickPaste]
    }

    private func singleSelectionHints(dropping count: Int) -> some View {
        let dropped = SingleHint.dropOrder.prefix(count)
        return HStack(spacing: Space.lg) {
            if clickToPaste && !dropped.contains(.clickPaste) {
                keyHint("click", "paste")
            }
            keyHint("↵", "paste")
            if focusedItemHasOCR {
                keyHint("⌥↵", "paste as text")
            }
            if !dropped.contains(.instant) {
                keyHint("⌘1–9", "instant")
            }
            if quickLookAvailable && !dropped.contains(.peek) {
                keyHint("space", "peek")
            }
            if !dropped.contains(.layout) {
                keyHint("⌥⌘1–5", "view")
            }
            if !dropped.contains(.settings) {
                keyHint("⌘,", "settings")
            }
            Spacer(minLength: 0)
            if hasPendingUndo {
                keyHint("⌘Z", "undo delete")
            } else {
                keyHint("⌘C", "copy")
                keyHint("⌘⌫", "delete")
            }
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(key)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .rounded))
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.hair)
                .background(Color.yankSubtleFill, in: RoundedRectangle(cornerRadius: Radius.xs))
            Text(label)
                .lineLimit(1)
        }
    }

    private var footerAccessibilityLabel: String {
        if selectionCount > 1 {
            if axUntrusted {
                return "Return copies \(selectionCount) items. Accessibility access is needed for auto-paste. Open System Settings to grant access."
            }
            return "Return pastes \(selectionCount) items. Escape to deselect. Command Delete to remove."
        }
        if axUntrusted {
            return "Return copies the clip. Accessibility access is needed for auto-paste. Open System Settings to grant access."
        }
        var parts = [
            clickToPaste ? "Click pastes, Return pastes" : "Return pastes",
            "Command 1 through 9 for instant paste"
        ]
        if quickLookAvailable { parts.append("Space to peek") }
        parts.append("Option Command 1 through 5 to switch layout")
        parts.append("Command comma for Settings")
        if hasPendingUndo {
            parts.append("Command Z to undo delete")
        } else {
            parts.append("Command C to copy")
            parts.append("Command Delete to remove")
        }
        if focusedItemHasOCR { parts.append("Option Return to paste as text") }
        return parts.joined(separator: ". ")
    }
}
