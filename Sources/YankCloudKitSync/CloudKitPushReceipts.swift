import Foundation

/// Durable per-record acknowledgement of the exact local version CloudKit accepted.
///
/// The enclosing UserDefaults key is container-scoped by `CloudKitSyncService`; this codec keeps
/// the payload versioned and strict so corrupt state causes a safe full replay instead of silently
/// suppressing local work.
enum CloudKitPushReceiptCodec {
    private struct Envelope: Codable {
        let version: Int
        let receipts: [String: TimeInterval]
    }

    enum Error: Swift.Error, Equatable {
        case payloadTooLarge(Int)
        case tooManyReceipts(Int)
        case unsupportedVersion(Int)
        case invalidRecordID(String)
        case duplicateRecordID(UUID)
        case invalidModifiedAt(String)
    }

    static let currentVersion = 1
    static let maximumReceiptCount = 100_000
    static let maximumPayloadBytes = 16 * 1_024 * 1_024

    static func encode(_ receipts: [UUID: Date]) throws -> Data {
        guard receipts.count <= maximumReceiptCount else {
            throw Error.tooManyReceipts(receipts.count)
        }
        var raw: [String: TimeInterval] = [:]
        raw.reserveCapacity(receipts.count)
        for (id, date) in receipts {
            let modifiedAt = date.timeIntervalSinceReferenceDate
            guard modifiedAt.isFinite else { throw Error.invalidModifiedAt(id.uuidString) }
            raw[id.uuidString] = modifiedAt
        }
        let data = try JSONEncoder().encode(Envelope(version: currentVersion, receipts: raw))
        guard data.count <= maximumPayloadBytes else {
            throw Error.payloadTooLarge(data.count)
        }
        return data
    }

    static func decode(_ data: Data) throws -> [UUID: Date] {
        guard data.count <= maximumPayloadBytes else {
            throw Error.payloadTooLarge(data.count)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == currentVersion else {
            throw Error.unsupportedVersion(envelope.version)
        }
        guard envelope.receipts.count <= maximumReceiptCount else {
            throw Error.tooManyReceipts(envelope.receipts.count)
        }

        var decoded: [UUID: Date] = [:]
        decoded.reserveCapacity(envelope.receipts.count)
        for (recordName, modifiedAt) in envelope.receipts {
            guard let id = UUID(uuidString: recordName) else {
                throw Error.invalidRecordID(recordName)
            }
            guard modifiedAt.isFinite else { throw Error.invalidModifiedAt(recordName) }
            guard decoded.updateValue(
                Date(timeIntervalSinceReferenceDate: modifiedAt),
                forKey: id
            ) == nil else {
                throw Error.duplicateRecordID(id)
            }
        }
        return decoded
    }
}
