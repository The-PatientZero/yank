import Cocoa
import Carbon

/// Sole owner of the process-wide Carbon hot-key event tap.
///
/// macOS installs exactly one application event handler, so the handler ref lives here once.
/// The app only binds one global shortcut: open clipboard history.
@MainActor
private final class CarbonHotkeyTap {
    static let shared = CarbonHotkeyTap()

    private struct Registration {
        let ref: EventHotKeyRef
        let onFire: @MainActor () -> Void
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]

    private static let signature = OSType(0x5941_4E4B) // "YANK"
    private static let clipboardHotkeyID: UInt32 = 1

    private init() {}

    /// Bind the clipboard shortcut to `onFire`, replacing any previous binding.
    /// Returns `false` if Carbon rejects the handler install or registration.
    @discardableResult
    func bind(keyCode: UInt32, modifierMask: UInt32, onFire: @escaping @MainActor () -> Void) -> Bool {
        unbind()
        guard installHandlerIfNeeded() else { return false }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.clipboardHotkeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifierMask, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.hotkey.error("RegisterEventHotKey failed: \(status)")
            return false
        }
        registrations[Self.clipboardHotkeyID] = Registration(ref: ref, onFire: onFire)
        return true
    }

    /// Drop the clipboard shortcut. Keeps the process-wide handler installed.
    func unbind() {
        guard let registration = registrations.removeValue(forKey: Self.clipboardHotkeyID) else { return }
        UnregisterEventHotKey(registration.ref)
    }

    func isBound() -> Bool { registrations[Self.clipboardHotkeyID] != nil }

    /// Routed here from the C trampoline once it has hopped back to the main actor.
    fileprivate func deliver(identifier: UInt32) {
        registrations[identifier]?.onFire()
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var firedID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                let identifier = firedID.id
                Task { @MainActor in CarbonHotkeyTap.shared.deliver(identifier: identifier) }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )

        guard status == noErr else {
            Log.hotkey.error("InstallEventHandler failed: \(status)")
            return false
        }
        return true
    }
}

/// The clipboard history global-shortcut facade.
/// Wraps the shared Carbon tap and translates the app's `HotkeyModifiers` into Carbon's mask.
@MainActor
struct HotkeyRegistry {
    /// Register the global clipboard-history shortcut, replacing any prior binding.
    /// Returns `false` if Carbon rejects it.
    @discardableResult
    func register(keyCode: UInt16, modifiers: HotkeyModifiers, onFire: @escaping @MainActor () -> Void) -> Bool {
        CarbonHotkeyTap.shared.bind(
            keyCode: UInt32(keyCode),
            modifierMask: Self.carbonModifierMask(for: modifiers),
            onFire: onFire
        )
    }

    /// Drop the global clipboard-history shortcut.
    func unregister() {
        CarbonHotkeyTap.shared.unbind()
    }

    func isRegistered() -> Bool {
        CarbonHotkeyTap.shared.isBound()
    }

    /// Translates the app's modifier flags into the bit mask Carbon expects.
    static func carbonModifierMask(for modifiers: HotkeyModifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.shift { mask |= UInt32(shiftKey) }
        if modifiers.command { mask |= UInt32(cmdKey) }
        if modifiers.option { mask |= UInt32(optionKey) }
        if modifiers.control { mask |= UInt32(controlKey) }
        return mask
    }
}
