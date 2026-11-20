import AppKit
import Testing
@testable import Yank

@Suite("Window Key Event Scope")
@MainActor
struct WindowKeyEventScopeTests {
    @Test("Key window receives its monitored event")
    func keyWindowReceivesItsMonitoredEvent() {
        let window = NSWindow()

        let shouldHandle = WindowKeyEventScope.shouldHandle(
            monitoredWindow: window,
            keyWindow: window
        )

        #expect(shouldHandle)
    }

    @Test("Non-key window passes the event through")
    func nonKeyWindowPassesEventThrough() {
        let monitoredWindow = NSWindow()
        let keyWindow = NSWindow()

        let shouldHandle = WindowKeyEventScope.shouldHandle(
            monitoredWindow: monitoredWindow,
            keyWindow: keyWindow
        )

        #expect(!shouldHandle)
    }

    @Test("Detached monitor passes the event through")
    func detachedMonitorPassesEventThrough() {
        let shouldHandle = WindowKeyEventScope.shouldHandle(
            monitoredWindow: nil,
            keyWindow: NSWindow()
        )

        #expect(!shouldHandle)
    }
}
