import SwiftUI
import AppKit

/// A key+modifier combination a user tried to bind, paired with whether it collides
/// with a reserved system shortcut. Pure value so the conflict rule is easy to reason
/// about (and test, if `HotkeyModifiers` ever moves into `YankCore`).
struct ShortcutCandidate {
    let keyCode: UInt16
    let modifiers: HotkeyModifiers

    private static let reservedCommandKeyCodes: Set<UInt16> = [
        12, 13, 9, 8, 7, 0, 6, 4, 46, 50, 49,
    ]

    private static let reservedControlCommandKeyCodes: Set<UInt16> = [
        49, 12,
    ]

    var conflictsWithReservedShortcut: Bool {
        let commandOnly = modifiers.command && !modifiers.shift && !modifiers.option && !modifiers.control
        if commandOnly && Self.reservedCommandKeyCodes.contains(keyCode) { return true }

        let controlCommandOnly = modifiers.control && modifiers.command && !modifiers.shift && !modifiers.option
        if controlCommandOnly && Self.reservedControlCommandKeyCodes.contains(keyCode) { return true }

        return false
    }

    /// A human label for the colliding combo, for the helper text and VoiceOver.
    var displayString: String {
        modifiers.displayString + (keyCodeNames[keyCode] ?? "?")
    }
}

/// Records keyboard shortcuts when active. Validates each candidate against the
/// reserved-shortcut set before committing; conflicts are surfaced to the caller so the
/// recorder can stay armed and announce the rejection.
struct KeyRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (UInt16, HotkeyModifiers) -> Void
    let onConflict: (String?) -> Void
    var onCancel: (() -> Void)? = nil

    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView()
        view.onRecord = onRecord
        view.onConflict = onConflict
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: KeyRecorderView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onConflict = onConflict
        nsView.onCancel = onCancel
        nsView.setRecording(isRecording)
    }
}

final class KeyRecorderView: NSView {
    private(set) var isRecording = false
    var onRecord: ((UInt16, HotkeyModifiers) -> Void)?
    var onConflict: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Host window already owns first-responder, so this just claims it. Announces
    /// the start of recording for VoiceOver.
    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        if recording {
            window?.makeFirstResponder(self)
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: "Recording shortcut. Press your new shortcut.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let escapeKeyCode: UInt16 = 53
        if event.keyCode == escapeKeyCode {
            onConflict?(nil)
            onCancel?()
            return
        }

        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]
        if modifierKeyCodes.contains(event.keyCode) { return }

        let mods = HotkeyModifiers(
            shift: event.modifierFlags.contains(.shift),
            command: event.modifierFlags.contains(.command),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control)
        )

        guard mods.shift || mods.command || mods.option || mods.control else { return }

        let candidate = ShortcutCandidate(keyCode: event.keyCode, modifiers: mods)
        if candidate.conflictsWithReservedShortcut {
            onConflict?(candidate.displayString)
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(candidate.displayString) is reserved by macOS. Try another shortcut.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }

        onConflict?(nil)
        onRecord?(event.keyCode, mods)
    }
}
