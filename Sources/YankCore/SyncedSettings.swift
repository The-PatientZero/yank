import Foundation

/// The slice of user preferences that follows the account across devices, plus the time the
/// value was last chosen. `updatedAt` is the whole conflict-resolution story: the strictly
/// newer side wins, and a tie leaves whatever the reading device already has in place.
public struct SyncedSettings: Equatable, Sendable {
    public let historyLimit: HistoryLimit
    /// Auto-delete window in days (0 = keep forever). Optional because records written by
    /// builds that predate the field carry no opinion: `nil` means "unknown", and adoption
    /// must keep the local value rather than resetting anyone's retention on upgrade.
    public let retentionDays: Int?
    /// When the local user last *chose* this value — not when it was last written to disk.
    /// A value adopted from another device carries that device's stamp verbatim, so the
    /// decision is stable no matter which device evaluates it.
    public let updatedAt: Date

    public init(historyLimit: HistoryLimit, retentionDays: Int? = nil, updatedAt: Date) {
        self.historyLimit = historyLimit
        self.retentionDays = retentionDays
        self.updatedAt = updatedAt
    }

    /// `false` when nobody has ever chosen this value on the local device — the state every
    /// install upgrades into. An unchosen value is never published, so upgrading alone cannot
    /// resize anyone's history or put a record in the zone.
    public var wasChosen: Bool { updatedAt > .distantPast }
}

/// Owns the choose-versus-adopt stamp rule in one place, so the macOS and iOS settings types
/// cannot drift apart on the thing that decides cross-device conflicts. Despite the name it
/// carries every synced preference (the name survives for source compatibility); the record
/// moves as one unit under a single stamp, so choosing either value publishes both.
public struct SyncedHistoryLimit: Equatable, Sendable {
    public private(set) var current: SyncedSettings

    public init(historyLimit: HistoryLimit, retentionDays: Int? = nil, updatedAt: Date = .distantPast) {
        self.current = SyncedSettings(
            historyLimit: historyLimit,
            retentionDays: retentionDays,
            updatedAt: updatedAt
        )
    }

    public var historyLimit: HistoryLimit { current.historyLimit }
    public var updatedAt: Date { current.updatedAt }

    /// A local user choice: stamped with the moment it was made. Returns whether anything
    /// actually changed, so callers announce a real choice and stay quiet otherwise.
    @discardableResult
    public mutating func choose(_ historyLimit: HistoryLimit, at now: Date = Date()) -> Bool {
        guard historyLimit != current.historyLimit else { return false }
        current = SyncedSettings(
            historyLimit: historyLimit,
            retentionDays: current.retentionDays,
            updatedAt: now
        )
        return true
    }

    /// A local retention choice, same stamp rule as `choose`.
    @discardableResult
    public mutating func chooseRetentionDays(_ days: Int, at now: Date = Date()) -> Bool {
        guard days != current.retentionDays else { return false }
        current = SyncedSettings(
            historyLimit: current.historyLimit,
            retentionDays: days,
            updatedAt: now
        )
        return true
    }

    /// A value adopted from another device. The remote stamp is kept verbatim — re-stamping
    /// would make this device look like the newest writer and bounce the value straight back
    /// at the device it came from. A remote record with no retention opinion (an older
    /// build's) leaves the local retention in place.
    public mutating func adopt(_ remote: SyncedSettings) {
        current = SyncedSettings(
            historyLimit: remote.historyLimit,
            retentionDays: remote.retentionDays ?? current.retentionDays,
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

public extension Notification.Name {
    /// A setting that syncs across devices was *chosen* locally, so the transport should
    /// reconcile it. Declared here beside the port rather than in the apps' notification list:
    /// `CloudKitSyncService` observes it itself, exactly as it observes local store changes.
    static let yankSyncedSettingsChanged = Notification.Name("yankSyncedSettingsChanged")
}
