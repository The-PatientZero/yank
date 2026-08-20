import Foundation

/// Why one remote record could not become a local clip, and how many resolution attempts it has
/// already cost.
struct CloudKitPullQuarantineEntry: Equatable {
    var reason: String
    var attemptCount: Int
}

/// Durable list of remote records the pull had to skip. A single unresolvable record must not
/// freeze the change feed, so it's skipped, remembered, and retried a bounded number of times.
/// Corrupt or oversized state degrades to "nothing quarantined" — it re-quarantines on the next pull.
enum CloudKitPullQuarantineCodec {
    private struct Envelope: Codable {
        let version: Int
        let entries: [String: StoredEntry]
    }

    private struct StoredEntry: Codable {
        let reason: String
        let attemptCount: Int
    }

    enum Error: Swift.Error, Equatable {
        case payloadTooLarge(Int)
        case tooManyEntries(Int)
        case unsupportedVersion(Int)
    }

    static let currentVersion = 1
    static let maximumEntryCount = 1_000
    static let maximumReasonLength = 200
    static let maximumPayloadBytes = 1_024 * 1_024

    static func truncatedReason(_ reason: String) -> String {
        String(reason.prefix(maximumReasonLength))
    }

    static func encode(_ entries: [String: CloudKitPullQuarantineEntry]) throws -> Data {
        guard entries.count <= maximumEntryCount else {
            throw Error.tooManyEntries(entries.count)
        }
        let stored = entries.mapValues {
            StoredEntry(reason: truncatedReason($0.reason), attemptCount: $0.attemptCount)
        }
        let data = try JSONEncoder().encode(
            Envelope(version: currentVersion, entries: stored)
        )
        guard data.count <= maximumPayloadBytes else {
            throw Error.payloadTooLarge(data.count)
        }
        return data
    }

    static func decode(_ data: Data) throws -> [String: CloudKitPullQuarantineEntry] {
        guard data.count <= maximumPayloadBytes else {
            throw Error.payloadTooLarge(data.count)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == currentVersion else {
            throw Error.unsupportedVersion(envelope.version)
        }
        guard envelope.entries.count <= maximumEntryCount else {
            throw Error.tooManyEntries(envelope.entries.count)
        }
        return envelope.entries.mapValues {
            CloudKitPullQuarantineEntry(reason: $0.reason, attemptCount: $0.attemptCount)
        }
    }
}
