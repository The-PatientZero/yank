import Foundation

enum SyncCopy {
    static let sectionDescription = "Your clips can follow you across devices through your own iCloud — free, no separate Yank account needed."
    static let optInDescription = "Off by default. When on, clips sync through your private iCloud database."
    static let localOnlySectionDescription = "This build keeps clips on this device. iCloud sync is available in the official signed app."
    static let iCloudRequirement = "iCloud account required. Sign in to iCloud in Settings to enable sync."
    /// First-run sentence for the sync switch on both apps. True whether the switch is on or off.
    static let welcomeSyncDescription = "When on, your clips sync through your private iCloud database and merge with your other devices. Removing a clip, the auto-delete window and the history limit apply on every device you sync."
    static let syncedRetention = "Clips and the auto-delete window sync across all your devices — removing a clip on one device removes it everywhere."

    /// The history limit itself syncs, so the scope of a change depends on whether sync is on.
    /// Saying "this device" while the choice propagates would be a lie the user only discovers
    /// after their other device is trimmed.
    static func historyLimitScope(syncEnabled: Bool) -> String {
        syncEnabled
            ? "This limit applies to every device signed in to your iCloud — changing it here changes it everywhere."
            : "This limit applies to this device."
    }

    /// Footer for the iOS choice to include history in device backups. The refill after a restore
    /// comes only from iCloud sync and is capped by the history limit, so the copy says exactly that.
    static func backupFooter(syncEnabled: Bool) -> String {
        let restore = syncEnabled
            ? "When off, a restored iPhone starts without history and gets recent clips back from iCloud sync, up to your history limit."
            : "Sync is off, so a restored iPhone would start without history."
        return "Off by default. \(restore) iOS treats this as a request and may still include the files."
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
            return "Clip details such as short text, tags and search data are end-to-end encrypted in iCloud. Images and large text use CloudKit's default encryption."
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

    // MARK: - Status vocabulary shared by both apps

    static let syncingHeadline = "Syncing…"
    static let syncedHeadline = "Synced"
    static let problemHeadline = "Sync problem"
    static let syncNow = "Sync now"
    static let tryAgain = "Try again"

    /// Symbol names per state, so the Mac and the iPhone draw the same shapes.
    enum Symbol {
        static let syncing = "arrow.triangle.2.circlepath"
        static let synced = "checkmark.icloud"
        static let problem = "exclamationmark.icloud"
        static let off = "xmark.icloud"
    }

    /// Under this many seconds the age reads "just now" instead of a relative time.
    private static let justNowSeconds: TimeInterval = 60

    /// "Synced just now" for the first minute, then "Synced 5 minutes ago" and so on.
    static func syncedText(lastSynced: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(lastSynced) < justNowSeconds {
            return "\(syncedHeadline) just now"
        }
        return "\(syncedHeadline) \(lastSynced.formatted(.relative(presentation: .named)))"
    }

    /// What the person can do about a failure. Anything not listed is a plain retry.
    enum FailureAction: Equatable {
        case openSettings
        case tryAgain
    }

    /// Actions for a failure, most useful first. `nil` kind is a failure with an unknown cause.
    static func actions(for kind: SyncFailureKind?) -> [FailureAction] {
        switch kind {
        case .some(.signedOut), .some(.accountRestricted):
            [.openSettings]
        case .some(.storageFull):
            [.openSettings, .tryAgain]
        default:
            [.tryAgain]
        }
    }

    #if os(macOS)
    static let openSettingsTitle = "Open System Settings"
    private static let storageFullPathHint = "On this Mac: System Settings, then Apple ID, then iCloud."
    #else
    static let openSettingsTitle = "Open Settings"
    private static let storageFullPathHint = "On this iPhone: Settings, then your name, then iCloud."
    #endif

    static func title(for action: FailureAction) -> String {
        switch action {
        case .openSettings: openSettingsTitle
        case .tryAgain: tryAgain
        }
    }

    /// Extra sentence naming where to go, for the failures that send the person to system settings.
    static func pathHint(for kind: SyncFailureKind?) -> String? {
        kind == .storageFull ? storageFullPathHint : nil
    }

    // MARK: - Clips that cannot upload

    static let waitingListHeading = "These clips can't be uploaded as they are"
    static let keepOnDevice = "Keep on this device"
    static let keepAllOnDevice = "Keep all on this device"
    static let deleteWaitingClip = "Delete"

    static func waitingCount(_ count: Int) -> String {
        count == 1 ? "1 clip waiting to sync" : "\(count) clips waiting to sync"
    }

    static func waitingReason(_ reason: SyncWaitingReason) -> String {
        switch reason {
        case .contentInvalid: "Its saved data is damaged and can't be uploaded"
        default: "Its saved file is missing on this device"
        }
    }

    /// The one line naming what is wrong, for the menu-bar tooltip and accessibility text.
    /// Nil while nothing needs attention.
    static func problemLine(status: SyncStatus, waitingCount: Int) -> String? {
        if case .failed(let message) = status { return message }
        return waitingCount > 0 ? Self.waitingCount(waitingCount) : nil
    }
}
