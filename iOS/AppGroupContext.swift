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

    func existingPasteboardOriginMarker(
        bundleIdentifier: String?
    ) -> IOSPasteboardOriginMarker? {
        IOSPasteboardOriginMarker.existing(
            bundleIdentifier: bundleIdentifier,
            defaults: defaults
        )
    }

    func pasteboardOriginMarkerForWrite(
        bundleIdentifier: String?,
        generateToken: () -> UUID = UUID.init
    ) -> IOSPasteboardOriginMarker? {
        IOSPasteboardOriginMarker.loadOrCreate(
            bundleIdentifier: bundleIdentifier,
            defaults: defaults,
            generateToken: generateToken
        )
    }
}

/// A collision-resistant, process-independent tag for a pasteboard item from this installation.
/// The type follows the host app's bundle identifier so forks do not share an identity,
/// while the random App Group token distinguishes separate installations of the same app.
struct IOSPasteboardOriginMarker: Equatable, Sendable {
    static let tokenDefaultsKey = "iosPasteboardOriginToken"
    private static let typeSuffix = ".pasteboard-origin"

    let pasteboardType: String
    let tokenData: Data

    static func existing(
        bundleIdentifier: String?,
        defaults: UserDefaults
    ) -> IOSPasteboardOriginMarker? {
        guard let pasteboardType = pasteboardType(bundleIdentifier: bundleIdentifier),
              let storedToken = defaults.string(forKey: tokenDefaultsKey),
              let token = UUID(uuidString: storedToken) else {
            return nil
        }
        return IOSPasteboardOriginMarker(
            pasteboardType: pasteboardType,
            tokenData: Data(token.uuidString.utf8)
        )
    }

    static func loadOrCreate(
        bundleIdentifier: String?,
        defaults: UserDefaults,
        generateToken: () -> UUID = UUID.init
    ) -> IOSPasteboardOriginMarker? {
        if let existing = existing(bundleIdentifier: bundleIdentifier, defaults: defaults) {
            return existing
        }
        guard let pasteboardType = pasteboardType(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let token = generateToken()
        let storedToken = token.uuidString
        defaults.set(storedToken, forKey: tokenDefaultsKey)
        guard defaults.string(forKey: tokenDefaultsKey) == storedToken else {
            return nil
        }
        return IOSPasteboardOriginMarker(
            pasteboardType: pasteboardType,
            tokenData: Data(storedToken.utf8)
        )
    }

    func matches(
        pasteboardTypes: [String],
        readData: (String) -> Data?
    ) -> Bool {
        pasteboardTypes.contains(pasteboardType)
            && readData(pasteboardType) == tokenData
    }

    private static func pasteboardType(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return bundleIdentifier + typeSuffix
    }
}
