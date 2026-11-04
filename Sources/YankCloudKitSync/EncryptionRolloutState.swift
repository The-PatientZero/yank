import Foundation
import CloudKit

/// The encryption rollout's persisted, per-container state. Every value describes one iCloud
/// account's zone, so `CloudKitSyncService.resetPersistedState` clears all of it on an account change.
struct EncryptionRolloutState {
    let defaults: UserDefaults
    let containerIdentifier: String

    private enum Name {
        static let encryptedOnly = "cloudkit.encryptedOnly"
        static let olderOrigins = "cloudkit.olderOrigins"
        static let sweepCompleted = "cloudkit.plaintextSweep"
        static let sweepAdopted = "cloudkit.plaintextSweep.adopted"
        static let sweepToken = "cloudkit.sweepToken"
        static let sweepAttempts = "cloudkit.sweepAttempts"
        static let sweepCount = "cloudkit.sweepCount"
        static let erased = "cloudkit.erased"
        static let olderSignals = "cloudkit.olderSignals"
        static let blankRepair = "cloudkit.blankRepair"
        static let deviceRecordIDs = "cloudkit.deviceRecordIDs"
        static let earliestCompletion = "cloudkit.earliestCompletion"
        static let olderActivity = "cloudkit.olderActivity"
    }

    static let allNames = [
        Name.encryptedOnly, Name.olderOrigins, Name.sweepCompleted, Name.sweepAdopted, Name.sweepToken,
        Name.sweepAttempts, Name.sweepCount, Name.erased, Name.olderSignals, Name.blankRepair,
        Name.deviceRecordIDs, Name.earliestCompletion, Name.olderActivity
    ]

    static func reset(containerIdentifier: String, defaults: UserDefaults) {
        for name in allNames {
            defaults.removeObject(forKey: "\(name).\(containerIdentifier)")
        }
    }

    private func key(_ name: String) -> String {
        "\(name).\(containerIdentifier)"
    }

    /// When plain content writing stopped. Sticky: once set it is never cleared, because
    /// reopening plain writing would put readable content back into iCloud.
    var encryptedOnlySince: Date? {
        get { defaults.object(forKey: key(Name.encryptedOnly)) as? Date }
        nonmutating set { defaults.set(newValue, forKey: key(Name.encryptedOnly)) }
    }

    /// When this device finished erasing the readable copies in iCloud.
    var sweepCompletedAt: Date? {
        get { defaults.object(forKey: key(Name.sweepCompleted)) as? Date }
        nonmutating set { defaults.set(newValue, forKey: key(Name.sweepCompleted)) }
    }

    /// Another device reported the sweep complete, so this one skips it.
    var sweepAdopted: Bool {
        get { defaults.bool(forKey: key(Name.sweepAdopted)) }
        nonmutating set { defaults.set(newValue, forKey: key(Name.sweepAdopted)) }
    }

    var isSweepDone: Bool { sweepCompletedAt != nil || sweepAdopted }

    var blankRepairDone: Bool {
        get { defaults.bool(forKey: key(Name.blankRepair)) }
        nonmutating set { defaults.set(newValue, forKey: key(Name.blankRepair)) }
    }

    /// The sweep's own paging position, separate from the pull's change token.
    var sweepToken: CKServerChangeToken? {
        get {
            guard let data = defaults.data(forKey: key(Name.sweepToken)) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        nonmutating set {
            guard let newValue,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true)
            else {
                defaults.removeObject(forKey: key(Name.sweepToken))
                return
            }
            defaults.set(data, forKey: key(Name.sweepToken))
        }
    }

    /// Failed or conflicting sweep saves per record name.
    var sweepAttempts: [String: Int] {
        get { defaults.dictionary(forKey: key(Name.sweepAttempts)) as? [String: Int] ?? [:] }
        nonmutating set { store(newValue, name: Name.sweepAttempts) }
    }

    /// Records the sweep has converted so far, across restarts.
    var sweepCount: Int {
        get { defaults.integer(forKey: key(Name.sweepCount)) }
        nonmutating set { defaults.set(newValue, forKey: key(Name.sweepCount)) }
    }

    /// Record name to the version stamp (`modifiedAt` in milliseconds) whose readable copy this
    /// device erased while pulling.
    var erasedVersions: [String: Int64] {
        get {
            (defaults.dictionary(forKey: key(Name.erased)) as? [String: NSNumber])?
                .mapValues(\.int64Value) ?? [:]
        }
        nonmutating set { store(newValue.mapValues { NSNumber(value: $0) }, name: Name.erased) }
    }

    /// Newest activity seen per device identifier that has no device record. Survives history trimming.
    var olderOrigins: [String: Date] {
        get { dates(Name.olderOrigins) }
        nonmutating set { storeDates(newValue, name: Name.olderOrigins) }
    }

    /// Origin to the time a readable copy came back, or an older build was seen writing after the
    /// switch. The empty origin stands for a writer that cannot be attributed.
    var olderSignals: [String: Date] {
        get { dates(Name.olderSignals) }
        nonmutating set { storeDates(newValue, name: Name.olderSignals) }
    }

    /// Identifiers of the devices that had a record when the zone was last read.
    var deviceRecordIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: key(Name.deviceRecordIDs)) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: key(Name.deviceRecordIDs)) }
    }

    /// The first day the switch can happen, from the last evaluation.
    var earliestCompletion: Date? {
        get { defaults.object(forKey: key(Name.earliestCompletion)) as? Date }
        nonmutating set { defaults.set(newValue, forKey: key(Name.earliestCompletion)) }
    }

    /// When activity from an older build was last seen, from the last evaluation.
    var olderActivityLastSeen: Date? {
        get { defaults.object(forKey: key(Name.olderActivity)) as? Date }
        nonmutating set { defaults.set(newValue, forKey: key(Name.olderActivity)) }
    }

    func clearSweepProgress() {
        defaults.removeObject(forKey: key(Name.sweepToken))
        defaults.removeObject(forKey: key(Name.sweepAttempts))
        defaults.removeObject(forKey: key(Name.sweepCount))
    }

    private func dates(_ name: String) -> [String: Date] {
        (defaults.dictionary(forKey: key(name)) as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSinceReferenceDate: $0) }
    }

    private func storeDates(_ value: [String: Date], name: String) {
        store(value.mapValues(\.timeIntervalSinceReferenceDate), name: name)
    }

    private func store(_ value: [String: Any], name: String) {
        if value.isEmpty {
            defaults.removeObject(forKey: key(name))
        } else {
            defaults.set(value, forKey: key(name))
        }
    }
}
