import Foundation

/// Stable per-install identifier, stamped into `ClipboardItem.deviceOrigin` for sync provenance.
enum DeviceIdentity {
    private static let key = "yank.deviceID"

    static let current = identifier(in: .standard)

    static func identifier(
        in defaults: UserDefaults,
        generateUUID: () -> UUID = { UUID() }
    ) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = generateUUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }
}
