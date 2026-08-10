import Foundation
import CloudKit
#if SWIFT_PACKAGE
import YankCore
#endif

/// Pure `SyncedSettings ⇄ CKRecord` mapping for the zone's singleton settings record.
/// No network — round-trips offline, so it is unit-tested directly.
///
/// The record is a singleton by construction: one fixed record name in the same private
/// zone the clips live in, so it rides the existing change feed and needs no second
/// subscription, zone, or change token.
enum SyncedSettingsCloudMapping {
    static let recordType = "SyncedSettings"
    static let recordName = "settings"

    enum Key {
        static let historyLimit = "historyLimit"
        static let updatedAt = "updatedAt"
    }

    static func recordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    static func record(for settings: SyncedSettings, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(in: zoneID))
        apply(settings, to: record)
        return record
    }

    /// Overwrites the mutable fields of an existing record — used on the push conflict path,
    /// where the server's copy has to be reused to keep its change tag.
    static func apply(_ settings: SyncedSettings, to record: CKRecord) {
        record[Key.historyLimit] = settings.historyLimit.rawValue
        record[Key.updatedAt] = settings.updatedAt
    }

    /// `nil` for any record this build cannot act on: a history limit outside the known tiers
    /// (a newer client's value, or a corrupt one) is rejected rather than coerced, because
    /// guessing would silently resize someone's history.
    static func settings(from record: CKRecord) -> SyncedSettings? {
        guard record.recordType == recordType,
              let rawLimit = record[Key.historyLimit] as? Int,
              let historyLimit = HistoryLimit(rawValue: rawLimit),
              let updatedAt = record[Key.updatedAt] as? Date else { return nil }
        return SyncedSettings(historyLimit: historyLimit, updatedAt: updatedAt)
    }

    /// What this build can read off a settings record. The stamp is read *independently* of the
    /// value: a record whose limit this build cannot interpret — a newer client's tier — still
    /// has a legible claim on the slot, and must not be overwritten by an older local choice.
    static func remoteRecord(from record: CKRecord) -> RemoteSettingsRecord? {
        guard record.recordType == recordType else { return nil }
        return RemoteSettingsRecord(
            settings: settings(from: record),
            // An unreadable stamp sorts oldest, so a real local choice can still repair the slot
            // while an install that never chose anything leaves it alone.
            updatedAt: record[Key.updatedAt] as? Date ?? .distantPast
        )
    }
}

/// A settings record as this build sees it: the usable value when there is one, and the stamp
/// either way.
struct RemoteSettingsRecord: Equatable {
    let settings: SyncedSettings?
    let updatedAt: Date
}
