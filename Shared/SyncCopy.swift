import Foundation

enum SyncCopy {
    static let sectionDescription = "Your clips can follow you across devices through your own iCloud — free, no separate Yank account needed."
    static let optInDescription = "Off by default. When on, clips sync through your private iCloud database."
    static let localOnlySectionDescription = "This build keeps clips on this device. iCloud sync is available in the official signed app."
    static let iCloudRequirement = "iCloud account required. Sign in to iCloud in Settings to enable sync."
    static let syncedRetention = "Clips and the auto-delete window sync across all your devices — removing a clip on one device removes it everywhere."

    /// The history limit itself syncs, so the scope of a change depends on whether sync is on.
    /// Saying "this device" while the choice propagates would be a lie the user only discovers
    /// after their other device is trimmed.
    static func historyLimitScope(syncEnabled: Bool) -> String {
        syncEnabled
            ? "This limit applies to every device signed in to your iCloud — changing it here changes it everywhere."
            : "This limit applies to this device."
    }

    /// Confirmation shown on the device making the reduction. It has to name the blast radius:
    /// the trim runs on every synced device, and nothing asks again over there.
    static func historyLimitReduction(syncEnabled: Bool) -> String {
        let scope = syncEnabled
            ? "on this device and on every device signed in to your iCloud"
            : "on this device"
        return "This permanently deletes your oldest unprotected clips to fit the new size, \(scope). Pinned, bookmarked, and tagged clips are always kept. This cannot be undone."
    }

    /// One plain sentence for the state of the move to end-to-end encrypted clip content.
    static func encryption(_ status: SyncEncryptionStatus) -> String {
        switch status {
        case .finishing(let earliestCompletion, let olderDeviceLastSeen):
            var parts = ["Finishing encryption. Update Yank on your other devices so clip text in iCloud can be kept private."]
            if let olderDeviceLastSeen {
                parts.append("Activity from an older version of Yank was last seen \(encryptionDate(olderDeviceLastSeen)).")
            }
            if let earliestCompletion, earliestCompletion > Date() {
                parts.append("The earliest this can finish is \(encryptionDate(earliestCompletion)).")
            }
            return parts.joined(separator: " ")
        case .removingReadableCopies:
            return "Removing readable copies of your clips from iCloud."
        case .complete:
            return "Clip text in iCloud is end-to-end encrypted."
        case .olderDeviceSeen(let lastSeen):
            return "A device on an older version of Yank cannot show new clips and can put readable copies back. Update Yank on it. Last seen \(encryptionDate(lastSeen))."
        }
    }

    private static func encryptionDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static let disabled = "iCloud sync is off."
    static let signedOut = "Sign in to iCloud to sync your clips across devices."
    static let notProvisioned = "iCloud sync is not available in this build."
}
