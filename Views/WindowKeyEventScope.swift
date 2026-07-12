import AppKit

@MainActor
enum WindowKeyEventScope {
    static func shouldHandle(
        monitoredWindow: NSWindow?,
        keyWindow: NSWindow?
    ) -> Bool {
        guard let monitoredWindow else { return false }
        return monitoredWindow === keyWindow
    }
}
