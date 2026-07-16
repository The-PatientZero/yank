import Foundation

/// Shared-container paths usable by extensions without touching UserDefaults.
struct AppGroupContainer: Sendable {
    static let identifier = "group.com.thepatientzero.yank"

    let url: URL

    static func live(fileManager: FileManager = .default) -> AppGroupContainer? {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else { return nil }
        return AppGroupContainer(url: url)
    }

    var keyboardProjectionURL: URL {
        url.appendingPathComponent(KeyboardHistoryProjection.filename)
    }

    var shareInbox: ShareCaptureInbox { ShareCaptureInbox(rootURL: url) }
}
