import Foundation

/// Why sync is in a failed state, as far as the sync transport can tell. An open set (a struct
/// with constants, not an enum) so a later value does not break a downstream `switch`: always
/// keep a `default`.
public struct SyncFailureKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The network or iCloud could not be reached.
    public static let offline = SyncFailureKind(rawValue: "offline")
    /// No iCloud account is signed in on this device.
    public static let signedOut = SyncFailureKind(rawValue: "signedOut")
    /// iCloud is restricted on this device (Screen Time or a managed account).
    public static let accountRestricted = SyncFailureKind(rawValue: "accountRestricted")
    /// The iCloud account is temporarily unavailable or its state could not be determined.
    public static let accountUnavailable = SyncFailureKind(rawValue: "accountUnavailable")
    /// The iCloud storage quota is used up.
    public static let storageFull = SyncFailureKind(rawValue: "storageFull")
    /// iCloud asked the app to slow down or is temporarily unavailable.
    public static let busy = SyncFailureKind(rawValue: "busy")
    /// Anything else.
    public static let other = SyncFailureKind(rawValue: "other")
}

/// A sync failure turned into one plain sentence. The sentence lives here once so both apps
/// show the same words for the same cause.
public struct SyncFailure: Equatable, Sendable {
    public let kind: SyncFailureKind
    /// The CloudKit error number behind an `other` failure, so a bug report can name it.
    public let code: Int?
    /// A sentence of its own for an `other` failure that is not a CloudKit error.
    public let detail: String?

    public init(kind: SyncFailureKind, code: Int? = nil, detail: String? = nil) {
        self.kind = kind
        self.code = code
        self.detail = detail
    }

    /// One short sentence a person can act on.
    public var message: String {
        switch kind {
        case .offline:
            "Can't reach iCloud. Check your connection, then try again."
        case .signedOut:
            "Sign in to iCloud to sync your clips across devices."
        case .accountRestricted:
            "iCloud is restricted on this device, so Yank can't sync. Check Screen Time or ask whoever manages this account."
        case .accountUnavailable:
            "iCloud isn't available right now. Try again in a moment."
        case .storageFull:
            "Your iCloud storage is full, so new clips can't upload. Free up space or add storage in your Apple ID's iCloud settings, then try again."
        case .busy:
            "iCloud is busy. Yank will try again shortly."
        default:
            if let detail { detail }
            else if let code { "Sync hit a problem (iCloud error \(code)). Try again, and mention the number if it keeps happening." }
            else { "Sync hit a problem. Try again in a moment." }
        }
    }
}

/// Why a clip cannot be uploaded as it is. Open set, like `SyncFailureKind`.
public struct SyncWaitingReason: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The clip's saved file is missing on this device.
    public static let contentFileMissing = SyncWaitingReason(rawValue: "contentFileMissing")
    /// The clip's saved data is damaged and cannot be represented in iCloud.
    public static let contentInvalid = SyncWaitingReason(rawValue: "contentInvalid")
}

/// A clip this device skipped because it cannot prepare it for upload. It keeps no push receipt,
/// so every later push retries it.
public struct SyncWaitingClip: Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let reason: SyncWaitingReason

    public init(id: UUID, reason: SyncWaitingReason) {
        self.id = id
        self.reason = reason
    }
}

/// Receives typed failures and the waiting-clip list from the sync transport. A separate
/// protocol so `SyncableStore` stays source compatible: a store that does not adopt it still
/// gets `markSyncFailed(_:)` with the same sentence.
@MainActor
public protocol SyncIssueReporting: AnyObject {
    func markSyncFailure(_ failure: SyncFailure)
    /// The clips the last push could not prepare; empty once none are waiting.
    func markClipsWaiting(_ clips: [SyncWaitingClip])
}
