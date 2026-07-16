import Foundation

/// The single App Group resolution boundary shared by the iOS host and its extensions.
/// Missing entitlements fail closed: callers receive `nil` instead of silently switching
/// to a process-local container or defaults suite.
struct AppGroupContext {
    static let identifier = AppGroupContainer.identifier

    let container: AppGroupContainer
    let defaults: UserDefaults

    init(containerURL: URL, defaults: UserDefaults) {
        self.container = AppGroupContainer(url: containerURL)
        self.defaults = defaults
    }

    static func live(fileManager: FileManager = .default) -> AppGroupContext? {
        guard let container = AppGroupContainer.live(fileManager: fileManager),
              let defaults = UserDefaults(suiteName: identifier) else {
            return nil
        }
        return AppGroupContext(containerURL: container.url, defaults: defaults)
    }

    var containerURL: URL { container.url }
    var historyURL: URL { container.url.appendingPathComponent("history.json") }
    var tombstonesURL: URL { container.url.appendingPathComponent("tombstones.json") }
    var blobsURL: URL { container.url.appendingPathComponent("blobs", isDirectory: true) }
    var keyboardProjectionURL: URL { container.keyboardProjectionURL }
    var shareInbox: ShareCaptureInbox { container.shareInbox }
}
