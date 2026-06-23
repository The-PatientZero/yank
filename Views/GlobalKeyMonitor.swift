import Cocoa
import SwiftUI

struct GlobalKeyMonitor: NSViewRepresentable {
    struct Handlers {
        let onUp: () -> Void
        let onDown: () -> Void
        let onExtendUp: () -> Void
        let onExtendDown: () -> Void
        let onEnter: () -> Void
        let onEscape: () -> Void
        let onDelete: () -> Void
        let onCopy: () -> Void
        let onPin: () -> Void
        let onBookmark: () -> Void
        let onSaveImage: () -> Void
        let onAddTag: () -> Void
        let onTabComplete: () -> Bool
        let onBackspace: () -> Bool
        let onPasteIndex: (Int) -> Void
        let onPasteAsTextKey: () -> Void
        let onSpace: () -> Bool
        let onLeft: () -> Bool
        let onRight: () -> Bool
        let onUndo: () -> Void
        let onFocusSearch: () -> Void
    }

    let handlers: Handlers

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // A local monitor is app-wide and does not depend on the representable already being
        // attached to a window. Capture `view` weakly only to resolve first responder at event time.
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            switch event.keyCode {
            case 126: // Up
                if event.modifierFlags.contains(.shift) {
                    handlers.onExtendUp()
                } else {
                    handlers.onUp()
                }
                return nil // Consume event
            case 125: // Down
                if event.modifierFlags.contains(.shift) {
                    handlers.onExtendDown()
                } else {
                    handlers.onDown()
                }
                return nil // Consume event
            case 36: // Enter (⌥↵ pastes an image's text instead)
                if event.modifierFlags.contains(.option) {
                    handlers.onPasteAsTextKey()
                } else {
                    handlers.onEnter()
                }
                return nil
            case 53: // Escape
                handlers.onEscape()
                return nil
            case 51: // Delete/Backspace
                if event.modifierFlags.contains(.command) {
                    handlers.onDelete()
                    return nil
                }
                if handlers.onBackspace() { return nil }
                return event
            case 8: // C (for Copy)
                if event.modifierFlags.contains(.command) {
                    // If text is selected in a text view, let the system handle native copy
                    if let responder = view?.window?.firstResponder, responder is NSTextView {
                        return event
                    }
                    handlers.onCopy()
                    return nil
                }
                return event
            case 35: // Cmd+P (P is 35)
                if event.modifierFlags.contains(.command) {
                    handlers.onPin()
                    return nil
                }
                return event
            case 11: // Cmd+B (B is 11)
                if event.modifierFlags.contains(.command) {
                    handlers.onBookmark()
                    return nil
                }
                return event
            case 1: // Cmd+S (S is 1)
                if event.modifierFlags.contains(.command) {
                    handlers.onSaveImage()
                    return nil
                }
                return event
            case 17: // Cmd+T (T is 17)
                if event.modifierFlags.contains(.command) {
                    handlers.onAddTag()
                    return nil
                }
                return event
            case 48: // Tab
                if handlers.onTabComplete() { return nil }
                return event
            case 49: // Space — Quick Look peek when not typing a query
                if handlers.onSpace() { return nil }
                return event
            case 123: // Left — 2D nav in tiled modes (else caret)
                if handlers.onLeft() { return nil }
                return event
            case 124: // Right — 2D nav in tiled modes (else caret)
                if handlers.onRight() { return nil }
                return event
            case 6:
                if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
                    handlers.onUndo()
                    return nil
                }
                return event
            case 3:
                if event.modifierFlags.contains(.command) {
                    handlers.onFocusSearch()
                    return nil
                }
                return event
            case 18, 19, 20, 21, 22, 23, 25, 26, 28: // ⌘1–⌘9 quick-paste
                if event.modifierFlags.contains(.command) {
                    let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
                    if let n = digits[event.keyCode] {
                        handlers.onPasteIndex(n)
                        return nil
                    }
                }
                return event
            default:
                return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var monitor: Any?

        /// Remove the local key monitor. Called deterministically from `dismantleNSView`,
        /// with `deinit` as a backstop.
        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}
