import Foundation

/// The slice of user preferences that follows the account across devices, plus the time the
/// value was last chosen. `updatedAt` is the whole conflict-resolution story: the strictly
/// newer side wins, and a tie leaves whatever the reading device already has in place.
public struct SyncedSettings: Equatable, Sendable {
    /// How many clips to keep.
    public let historyLimit: HistoryLimit
    /// Auto-delete window in minutes (0 = keep forever). Optional because records written by
    /// builds that predate the field carry no opinion: `nil` means "unknown", and adoption
    /// must keep the local value rather than resetting anyone's retention on upgrade.
    public let retentionMinutes: Int?
    /// When the local user last *chose* this value — not when it was last written to disk.
    /// A value adopted from another device carries that device's stamp verbatim, so the
    /// decision is stable no matter which device evaluates it.
    public let updatedAt: Date

    /// Creates settings stamped with the time the value was chosen.
    public init(historyLimit: HistoryLimit, retentionMinutes: Int? = nil, updatedAt: Date) {
        self.historyLimit = historyLimit
        self.retentionMinutes = retentionMinutes
        self.updatedAt = updatedAt
    }

    /// Minutes in one day, the unit of the window builds before hour windows store and sync.
    public static let minutesPerDay = 1_440

    /// The whole-day window for builds that only read days. A part day rounds up, so such a build
    /// never deletes a clip the chosen window would keep.
    public static func legacyDays(forMinutes minutes: Int) -> Int {
        (minutes + minutesPerDay - 1) / minutesPerDay
    }

    /// `false` when nobody has ever chosen this value on the local device — the state every
    /// install upgrades into. An unchosen value is never published, so upgrading alone cannot
    /// resize anyone's history or put a record in the zone.
    public var wasChosen: Bool { updatedAt > .distantPast }
}

/// Owns the choose-versus-adopt stamp rule so macOS and iOS settings types cannot drift on
/// cross-device conflict resolution. Despite the name (kept for source compatibility) it carries
/// every synced preference as one unit under a single stamp, so choosing either publishes both.
public struct SyncedHistoryLimit: Equatable, Sendable {
    /// The settings together with the stamp they carry.
    public private(set) var current: SyncedSettings

    /// Creates a value; the default `updatedAt` of `.distantPast` means nobody has chosen it.
    public init(historyLimit: HistoryLimit, retentionMinutes: Int? = nil, updatedAt: Date = .distantPast) {
        self.current = SyncedSettings(
            historyLimit: historyLimit,
            retentionMinutes: retentionMinutes,
            updatedAt: updatedAt
        )
    }

    /// The current history cap.
    public var historyLimit: HistoryLimit { current.historyLimit }
    /// When the current value was last chosen, on this or another device.
    public var updatedAt: Date { current.updatedAt }

    /// A local user choice: stamped with the moment it was made. Returns whether anything
    /// actually changed, so callers announce a real choice and stay quiet otherwise.
    @discardableResult
    public mutating func choose(_ historyLimit: HistoryLimit, at now: Date = Date()) -> Bool {
        guard historyLimit != current.historyLimit else { return false }
        current = SyncedSettings(
            historyLimit: historyLimit,
            retentionMinutes: current.retentionMinutes,
            updatedAt: now
        )
        return true
    }

    /// A local retention choice, same stamp rule as `choose`.
    @discardableResult
    public mutating func chooseRetentionMinutes(_ minutes: Int, at now: Date = Date()) -> Bool {
        guard minutes != current.retentionMinutes else { return false }
        current = SyncedSettings(
            historyLimit: current.historyLimit,
            retentionMinutes: minutes,
            updatedAt: now
        )
        return true
    }

    /// A value adopted from another device. The remote stamp is kept verbatim — re-stamping would
    /// make this device look like the newest writer and bounce the value back at its origin. A
    /// remote record with no retention opinion (an older build's) leaves local retention in place.
    public mutating func adopt(_ remote: SyncedSettings) {
        current = SyncedSettings(
            historyLimit: remote.historyLimit,
            retentionMinutes: remote.retentionMinutes ?? current.retentionMinutes,
            updatedAt: remote.updatedAt
        )
    }
}

/// Settings contract consumed by the CloudKit sync transport, mirroring `SyncableStore`:
/// the transport declares the port and the app's settings layer adapts to it, so the sync
/// engine never imports `SettingsManager` / `IOSSettings`.
@MainActor
public protocol SyncedSettingsStore: AnyObject {
    /// The locally effective synced settings, or `nil` when preferences cannot be read
    /// (iOS without its App Group).
    var syncedSettings: SyncedSettings? { get }

    /// Adopt a strictly newer remote value. `SyncedHistoryLimit.adopt` exists so every
    /// implementation keeps the remote stamp verbatim rather than stamping the write time.
    func applySyncedSettings(_ settings: SyncedSettings)
}

/// Notifications for synced settings.
public extension Notification.Name {
    /// A setting that syncs across devices was *chosen* locally, so the transport should
    /// reconcile it. Declared here beside the port rather than in the apps' notification list:
    /// `CloudKitSyncService` observes it itself, exactly as it observes local store changes.
    static let yankSyncedSettingsChanged = Notification.Name("yankSyncedSettingsChanged")
}
