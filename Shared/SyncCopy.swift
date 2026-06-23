import Foundation

enum SyncCopy {
    static let sectionDescription = "Your clips can follow you across devices through your own iCloud — free, no separate Yank account needed."
    static let optInDescription = "Off by default. When on, clips sync through your private iCloud database."
    static let localOnlySectionDescription = "This build keeps clips on this device. iCloud sync is available in the official signed app."
    static let iCloudRequirement = "iCloud account required. Sign in to iCloud in Settings to enable sync."
    static let perDeviceRetention = "Clips sync across all your devices. Auto-delete propagates via sync — removing a clip on one device removes it everywhere."
    static let disabled = "iCloud sync is off."
    static let signedOut = "Sign in to iCloud to sync your clips across devices."
    static let notProvisioned = "iCloud sync is not available in this build."
}
