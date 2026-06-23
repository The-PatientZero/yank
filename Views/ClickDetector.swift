import SwiftUI
import AppKit

struct ClickDetector: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags, Int) -> Void
    
    class ClickView: NSView {
        var onClick: ((NSEvent.ModifierFlags, Int) -> Void)?
        private var mouseDownPoint: CGPoint?
        private var mouseDownModifiers: NSEvent.ModifierFlags = []
        private var mouseDownClickCount = 1
        private static let clickMovementTolerance: CGFloat = 4
        
        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            mouseDownModifiers = event.modifierFlags
            mouseDownClickCount = event.clickCount
            // Continue the event through the responder chain rather than terminating it
            // here, so the cell's SwiftUI drag-out still sees the press-and-drag sequence
            // instead of having it swallowed at this overlay.
            super.mouseDown(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownPoint = nil
                mouseDownModifiers = []
                mouseDownClickCount = 1
            }
            let mouseUpPoint = convert(event.locationInWindow, from: nil)
            if let mouseDownPoint, Self.isClick(from: mouseDownPoint, to: mouseUpPoint) {
                onClick?(mouseDownModifiers, max(mouseDownClickCount, event.clickCount))
            }
            super.mouseUp(with: event)
        }

        private static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
            abs(end.x - start.x) <= clickMovementTolerance &&
                abs(end.y - start.y) <= clickMovementTolerance
        }
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = ClickView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.onClick = onClick
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let clickView = nsView as? ClickView {
            clickView.onClick = onClick
        }
    }
}

// MARK: - Modifier Flags Extension
extension NSEvent.ModifierFlags {
    var hasCommand: Bool {
        self.contains(.command)
    }
    
    var hasShift: Bool {
        self.contains(.shift)
    }
}
