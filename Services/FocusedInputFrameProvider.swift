import AppKit
@preconcurrency import ApplicationServices

#if DEBUG
enum DebugQuickPickerSimulation {
    static let mouseAnchorArgument = "-YankDebugQuickPickerMouseAnchor"
    static let pointerSettleDelay: TimeInterval = 0.8

    static var mouseAnchorEnabled: Bool {
        mouseAnchorEnabled(arguments: ProcessInfo.processInfo.arguments)
    }

    static func mouseAnchorEnabled(arguments: [String]) -> Bool {
        arguments.contains(mouseAnchorArgument)
    }
}
#endif

@MainActor
enum FocusedInputFrameProvider {
    static func frame(preferredApp: NSRunningApplication?) -> NSRect? {
        if let frame = accessibilityFrame(preferredApp: preferredApp) {
            return frame
        }
        return pointerFrame(
            at: NSEvent.mouseLocation,
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    private static func accessibilityFrame(preferredApp: NSRunningApplication?) -> NSRect? {
        guard AXIsProcessTrusted(),
              let app = usableApp(preferredApp ?? NSWorkspace.shared.frontmostApplication) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedElement = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }

        if let caretFrame = selectedTextBounds(in: focusedElement) {
            return appKitRect(fromTopLeftScreenRect: caretFrame)
        }

        guard isTextEntryElement(focusedElement),
              let frame = elementFrame(focusedElement) else {
            return nil
        }
        return appKitRect(fromTopLeftScreenRect: frame)
    }

    nonisolated static func pointerFrame(at location: NSPoint, screenFrames: [NSRect]) -> NSRect? {
        guard screenFrames.contains(where: { $0.contains(location) }) else { return nil }
        return NSRect(x: location.x, y: location.y, width: 1, height: 20)
    }

    private static func usableApp(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app,
              app.processIdentifier > 0,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return app
    }

    private static func selectedTextBounds(in element: AXUIElement) -> NSRect? {
        guard let rangeValue = axValueAttribute(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            type: .cfRange
        ) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        guard result == .success,
              let rawBoundsValue = boundsValue,
              CFGetTypeID(rawBoundsValue) == AXValueGetTypeID() else {
            return nil
        }
        let rectValue = rawBoundsValue as! AXValue
        guard AXValueGetType(rectValue) == .cgRect else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(rectValue, .cgRect, &rect), isUsable(rect) else { return nil }
        return rect
    }

    private static func elementFrame(_ element: AXUIElement) -> NSRect? {
        guard let positionValue = axValueAttribute(element, kAXPositionAttribute as CFString, type: .cgPoint),
              let sizeValue = axValueAttribute(element, kAXSizeAttribute as CFString, type: .cgSize) else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        let rect = CGRect(origin: position, size: size)
        guard isUsable(rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private static func isTextEntryElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
            || subrole == (kAXSearchFieldSubrole as String)
            || subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func axValueAttribute(
        _ element: AXUIElement,
        _ name: CFString,
        type: AXValueType
    ) -> AXValue? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        return axValue
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func appKitRect(fromTopLeftScreenRect rect: NSRect) -> NSRect {
        appKitRect(fromTopLeftScreenRect: rect, mainScreenFrame: NSScreen.main?.frame)
    }

    nonisolated static func appKitRect(fromTopLeftScreenRect rect: NSRect, mainScreenFrame: NSRect?) -> NSRect {
        guard let mainMaxY = mainScreenFrame?.maxY else { return rect }
        return NSRect(
            x: rect.origin.x,
            y: mainMaxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 0
            && rect.height >= 0
    }
}
