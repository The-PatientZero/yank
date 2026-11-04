import Foundation
import CloudKit

/// What one install says about itself in the account's small device zone: it reads and writes the
/// encrypted copy of clip content. Pure mapping, like `SyncedSettingsCloudMapping`.
///
/// The records live in their own zone on purpose. Yank 1.2.x quarantines any record type it does
/// not know as unreadable, and never fetches a zone it does not know.
enum CloudKitDeviceRegistry {
    static let recordType = "DeviceSyncFormat"
    static let zoneName = "YankDevicesZone"

    /// The only value this build writes for `encryptedFormat`.
    static let currentFormat = 1

    /// Most older-device identifiers one record publishes.
    static let maximumOlderOrigins = 50

    enum Key {
        static let encryptedFormat = "encryptedFormat"
        static let encryptedOnlySince = "encryptedOnlySince"
        static let sweepCompletedAt = "sweepCompletedAt"
        static let olderOrigins = "olderOrigins"
        /// Last-seen time of each entry in `olderOrigins`, same order. Absent in records written by
        /// builds that publish only the identifiers.
        static let olderOriginSeen = "olderOriginSeen"
    }

    /// The fields a device publishes about itself. The record name is the device identifier; the
    /// soak start is the record's server `creationDate`, so no device clock decides anything.
    struct Content: Equatable {
        var encryptedOnlySince: Date?
        var sweepCompletedAt: Date?
        var olderOrigins: [String]
        /// When each origin in `olderOrigins` was last active, same order. May be shorter than
        /// `olderOrigins` (or empty) when the record comes from a build that did not publish times.
        var olderOriginSeen: [Date] = []

        /// When `origin` was last active according to this record, if the record says.
        func lastSeen(of origin: String) -> Date? {
            guard let index = olderOrigins.firstIndex(of: origin), olderOriginSeen.indices.contains(index) else {
                return nil
            }
            return olderOriginSeen[index]
        }

        /// Compares the way the server stores the values: dates to the millisecond, the list as a set.
        func matches(_ other: Content) -> Bool {
            Self.milliseconds(encryptedOnlySince) == Self.milliseconds(other.encryptedOnlySince)
                && Self.milliseconds(sweepCompletedAt) == Self.milliseconds(other.sweepCompletedAt)
                && Set(olderOrigins) == Set(other.olderOrigins)
                && olderOrigins.allSatisfy { Self.milliseconds(lastSeen(of: $0)) == Self.milliseconds(other.lastSeen(of: $0)) }
        }

        private static func milliseconds(_ date: Date?) -> Int64? {
            date.map(ClipboardCloudMapping.millisecondStamp)
        }
    }

    struct DeviceState: Equatable {
        let deviceID: String
        let creationDate: Date?
        let content: Content
    }

    static func recordID(deviceID: String, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: deviceID, zoneID: zoneID)
    }

    /// Writes `content` onto `existing` (a server-fetched record, so its creation date survives)
    /// or onto a new record. Optional fields are only assigned when set, and cleared otherwise.
    static func record(
        for deviceID: String,
        content: Content,
        in zoneID: CKRecordZone.ID,
        existing: CKRecord?
    ) -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: recordType,
            recordID: recordID(deviceID: deviceID, in: zoneID)
        )
        record[Key.encryptedFormat] = currentFormat
        record[Key.encryptedOnlySince] = content.encryptedOnlySince
        record[Key.sweepCompletedAt] = content.sweepCompletedAt
        record[Key.olderOrigins] = content.olderOrigins.isEmpty ? nil : Array(content.olderOrigins.prefix(maximumOlderOrigins))
        // Only written when every published origin has a time, so the two lists stay aligned.
        let publishedCount = min(content.olderOrigins.count, maximumOlderOrigins)
        record[Key.olderOriginSeen] = publishedCount > 0 && content.olderOriginSeen.count >= publishedCount
            ? Array(content.olderOriginSeen.prefix(publishedCount))
            : nil
        return record
    }

    static func state(from record: CKRecord) -> DeviceState? {
        guard record.recordType == recordType,
              let format = record[Key.encryptedFormat] as? Int, format >= currentFormat else { return nil }
        return DeviceState(
            deviceID: record.recordID.recordName,
            creationDate: record.creationDate,
            content: Content(
                encryptedOnlySince: record[Key.encryptedOnlySince] as? Date,
                sweepCompletedAt: record[Key.sweepCompletedAt] as? Date,
                olderOrigins: record[Key.olderOrigins] as? [String] ?? [],
                olderOriginSeen: record[Key.olderOriginSeen] as? [Date] ?? []
            )
        )
    }
}

/// How long the rollout waits, and how far back it looks for older devices.
enum EncryptionRolloutTiming {
    /// Dual-writing continues at least this long after the earliest device record was created,
    /// so a device that syncs rarely gets the chance to update and publish its own record.
    static let minimumDualWriteDuration: TimeInterval = 14 * 24 * 60 * 60
    /// An origin with no device record counts as an older device while its activity is this recent.
    static let legacyActivityWindow: TimeInterval = 60 * 24 * 60 * 60
    /// Pause between rollout evaluations within one launch; the first one is never skipped.
    static let evaluationInterval: TimeInterval = 60 * 60
    /// A readable copy that came back counts against "complete" this long.
    static let olderDeviceSignalWindow: TimeInterval = 14 * 24 * 60 * 60
    /// Older-device evidence kept on this device, newest first.
    static let persistedOriginLimit = 200
    /// Records of the pull-time erase remembered, newest first.
    static let erasedVersionLimit = 2000

    #if DEBUG
    static var soak: TimeInterval { DebugRolloutOverrides.soakSeconds ?? minimumDualWriteDuration }
    static var activityWindow: TimeInterval { DebugRolloutOverrides.legacyActivityWindowSeconds ?? legacyActivityWindow }
    static var interval: TimeInterval { DebugRolloutOverrides.evaluationIntervalSeconds ?? evaluationInterval }
    #else
    static var soak: TimeInterval { minimumDualWriteDuration }
    static var activityWindow: TimeInterval { legacyActivityWindow }
    static var interval: TimeInterval { evaluationInterval }
    #endif
}

/// Bounds of the one-time sweep that erases readable copies already in iCloud.
enum PlaintextSweepLimits {
    /// Records one sweep invocation converts before it hands control back.
    static let recordsPerInvocation = 500
    /// Records requested per page.
    static let pageSize = 100
    /// Failed or conflicting saves of one record before the sweep stops waiting for it.
    static let attemptLimit = 3
    /// Pause before the next bounded invocation continues an unfinished sweep.
    static let continuationDelay: Duration = .seconds(2)

    #if DEBUG
    static var effectivePageSize: Int { DebugRolloutOverrides.sweepPageSize ?? pageSize }
    #else
    static var effectivePageSize: Int { pageSize }
    #endif
}
