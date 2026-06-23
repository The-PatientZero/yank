import SwiftUI

struct FooterHintsBar: View {
    var selectionCount: Int
    var clickToPaste: Bool = false
    var hasPendingUndo: Bool = false
    var focusedItemHasOCR: Bool = false
    var quickLookAvailable: Bool = true
    var axUntrusted: Bool = false
    /// Opens System Settings and polls for the grant. Injected so the footer drives the same shared
    /// permission object Settings uses (one source of truth), not a fire-and-forget static call.
    var onGrantAccess: () -> Void = { AccessibilityPermission.openSettings() }

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
                    keyHint("⌫", "delete")
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
                    if clickToPaste {
                        keyHint("click", "paste")
                        keyHint("↵", "paste")
                    } else {
                        keyHint("↵", "paste")
                    }
                    if focusedItemHasOCR {
                        keyHint("⌥↵", "paste as text")
                    }
                    keyHint("⌘1–9", "instant")
                    if quickLookAvailable {
                        keyHint("space", "peek")
                    }
                    Spacer()
                    if hasPendingUndo {
                        keyHint("⌘Z", "undo delete")
                    } else {
                        keyHint("⌘C", "copy")
                        keyHint("⌫", "delete")
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

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(key)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .rounded))
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.hair)
                .background(Color.yankSubtleFill, in: RoundedRectangle(cornerRadius: Radius.xs))
            Text(label)
        }
    }

    private var footerAccessibilityLabel: String {
        if selectionCount > 1 {
            if axUntrusted {
                return "Return copies \(selectionCount) items. Accessibility access is needed for auto-paste. Open System Settings to grant access."
            }
            return "Return pastes \(selectionCount) items. Escape to deselect. Delete to remove."
        }
        if axUntrusted {
            return "Return copies the clip. Accessibility access is needed for auto-paste. Open System Settings to grant access."
        }
        var parts = [
            clickToPaste ? "Click pastes, Return pastes" : "Return pastes",
            "Command 1 through 9 for instant paste"
        ]
        if quickLookAvailable { parts.append("Space to peek") }
        if hasPendingUndo { parts.append("Command Z to undo delete") }
        if focusedItemHasOCR { parts.append("Option Return to paste as text") }
        return parts.joined(separator: ". ")
    }
}
