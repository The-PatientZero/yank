import Foundation
import CloudKit
import os
#if SWIFT_PACKAGE
import YankCore
#endif

/// Pure `ClipboardItem ⇄ CKRecord` mapping for scalar fields. Blobs attach as `CKAsset`.
/// No network — round-trips offline, so it is unit-tested directly.
enum ClipboardCloudMapping {
    static let recordType = "ClipboardItem"

    enum Key {
        static let type = "type"
        static let timestamp = "timestamp"
        static let sourceApp = "sourceApp"
        static let textContent = "textContent"
        static let textFilename = "textFilename"
        static let imageFilename = "imageFilename"
        static let isPinned = "isPinned"
        static let isBookmarked = "isBookmarked"
        static let tags = "tags"
        static let ocrText = "ocrText"
        static let isTruncated = "isTruncated"
        static let originalSizeBytes = "originalSizeBytes"
        static let modifiedAt = "modifiedAt"
        static let deletedAt = "deletedAt"
        static let deviceOrigin = "deviceOrigin"
        static let blob = "blob"
        static let hasRichContent = "hasRichContent"
        static let searchIndex = "searchIndex"
        static let aiTags = "aiTags"
        static let aiTitle = "aiTitle"
        static let aiEnrichedAt = "aiEnrichedAt"
        /// End-to-end encrypted copy of the clip content, set through `encryptedValues`.
        static let encContent = "encContent"
    }

    /// Largest non-asset record size this build writes. CloudKit caps a record near 1 MB, and the
    /// plain fields plus the encrypted copy hold the same content twice.
    static let maximumRecordContentBytes = 900_000

    /// CloudKit does not keep sub-millisecond `Date` precision, and rounding may differ by one
    /// millisecond between writer and reader.
    private static let contentStampToleranceMilliseconds: Int64 = 1

    /// The values stored in `Key.encContent`. `contentStamp` names the version of the clip the
    /// copy belongs to: a device that edits only the plain fields leaves it behind, which tells
    /// readers the plain fields are newer. `plainFields` lists content fields left out of the
    /// payload because the record would not fit, which readers take from the plain keys.
    struct EncryptedContentPayload: Codable {
        static let currentVersion = 1

        var version: Int
        var contentStamp: Int64
        var sourceApp: String?
        var textContent: String?
        var ocrText: String?
        var searchIndex: String?
        var tags: [String]
        var aiTags: [String]
        var aiTitle: String?
        var plainFields: [String]
    }

    /// Reads only the format version, so a payload from a newer build is recognised even when
    /// the rest of it does not decode here.
    private struct EncryptedContentHeader: Decodable {
        let version: Int
    }

    /// The content fields of a clip that live in the encrypted copy.
    struct SyncedContent {
        var sourceApp: String?
        var textContent: String?
        var ocrText: String?
        var searchIndex: String?
        var tags: [String]
        var aiTags: [String]
        var aiTitle: String?
    }

    enum EncryptedCopyState {
        case absent
        case unreadable
        /// Written by a build with a newer payload format; read through the plain fields.
        case newerFormat
        /// The payload belongs to an older version of the clip than the plain fields.
        case stale
        case current(EncryptedContentPayload)
    }

    /// Why a record's encrypted copy has to be rewritten by this device.
    enum EncryptedRefreshReason {
        case missing
        case unreadable
        case stale
        case tombstoneHoldsContent
    }

    /// Whole milliseconds, the precision CloudKit keeps for dates.
    static func millisecondStamp(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 1_000).rounded())
    }

    static func record(from item: ClipboardItem, in zoneID: CKRecordZone.ID, blobURL: URL? = nil) -> CKRecord? {
        guard let filenames = validatedBlobFilenames(
            type: item.type,
            textFilename: item.textFilename,
            imageFilename: item.imageFilename
        ), blobURL == nil || filenames.textFilename != nil || filenames.imageFilename != nil else {
            return nil
        }

        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record[Key.type] = item.type.rawValue
        record[Key.timestamp] = item.timestamp
        record[Key.sourceApp] = item.sourceApp
        record[Key.textContent] = item.textContent
        record[Key.textFilename] = filenames.textFilename
        record[Key.imageFilename] = filenames.imageFilename
        record[Key.isPinned] = item.isPinned ? 1 : 0
        record[Key.isBookmarked] = item.isBookmarked ? 1 : 0
        record[Key.tags] = item.tags
        record[Key.ocrText] = item.ocrText
        record[Key.isTruncated] = item.isTruncated ? 1 : 0
        record[Key.originalSizeBytes] = item.originalSizeBytes
        record[Key.searchIndex] = item.searchIndex
        record[Key.aiTags] = item.aiTags
        record[Key.aiTitle] = item.aiTitle
        record[Key.aiEnrichedAt] = item.aiEnrichedAt
        record[Key.modifiedAt] = item.modifiedAt
        record[Key.deletedAt] = item.deletedAt
        record[Key.deviceOrigin] = item.deviceOrigin
        record[Key.hasRichContent] = item.hasRichContent ? 1 : 0
        if !item.isDeleted {
            record.encryptedValues[Key.encContent] = encryptedContentData(for: item)
        }
        if let blobURL {
            record[Key.blob] = CKAsset(fileURL: blobURL)
        }
        return record
    }

    /// Builds the encrypted copy. When plain fields plus payload would exceed the record budget,
    /// the largest of the search index, OCR text and text moves out of the payload and is read
    /// from its plain key instead; the search index goes first because it is derived data.
    private static func encryptedContentData(for item: ClipboardItem) -> Data? {
        var payload = EncryptedContentPayload(
            version: EncryptedContentPayload.currentVersion,
            contentStamp: millisecondStamp(item.modifiedAt),
            sourceApp: item.sourceApp,
            textContent: item.textContent,
            ocrText: item.ocrText,
            searchIndex: item.searchIndex,
            tags: item.tags,
            aiTags: item.aiTags,
            aiTitle: item.aiTitle,
            plainFields: []
        )
        let plainBytes = plainContentByteCount(of: item)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        while true {
            guard let data = try? encoder.encode(payload) else {
                syncLog.error(
                    "could not encode the encrypted copy of clip \(item.id.uuidString, privacy: .public)"
                )
                return nil
            }
            guard plainBytes + data.count > maximumRecordContentBytes,
                  let largest = largestMovablePayloadField(in: payload) else { return data }
            syncLog.info(
                "clip \(item.id.uuidString, privacy: .public) is too large to hold two copies; leaving \(largest, privacy: .public) out of the encrypted copy"
            )
            switch largest {
            case Key.searchIndex: payload.searchIndex = nil
            case Key.ocrText: payload.ocrText = nil
            default: payload.textContent = nil
            }
            payload.plainFields.append(largest)
        }
    }

    private static func largestMovablePayloadField(in payload: EncryptedContentPayload) -> String? {
        let candidates: [(key: String, bytes: Int)] = [
            (Key.searchIndex, payload.searchIndex?.utf8.count ?? 0),
            (Key.ocrText, payload.ocrText?.utf8.count ?? 0),
            (Key.textContent, payload.textContent?.utf8.count ?? 0)
        ]
        // `max` keeps the first of equal elements, so ties fall to the search index first.
        return candidates.max { $0.bytes < $1.bytes }.flatMap { $0.bytes > 0 ? $0.key : nil }
    }

    private static func plainContentByteCount(of item: ClipboardItem) -> Int {
        let strings = [item.sourceApp, item.textContent, item.ocrText, item.searchIndex, item.aiTitle]
        let stringBytes = strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        let tagBytes = (item.tags + item.aiTags).reduce(0) { $0 + $1.utf8.count }
        return stringBytes + tagBytes
    }

    /// Field-wise equality over exactly what `record(from:)` writes — `ClipboardItem`'s own
    /// `==` is identity-only, and local-only state (`richFilename`) deliberately stays out.
    static func syncedFieldsMatch(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.timestamp == rhs.timestamp
            && lhs.sourceApp == rhs.sourceApp
            && lhs.textContent == rhs.textContent
            && lhs.textFilename == rhs.textFilename
            && lhs.imageFilename == rhs.imageFilename
            && lhs.isPinned == rhs.isPinned
            && lhs.isBookmarked == rhs.isBookmarked
            && lhs.tags == rhs.tags
            && lhs.ocrText == rhs.ocrText
            && lhs.isTruncated == rhs.isTruncated
            && lhs.originalSizeBytes == rhs.originalSizeBytes
            && lhs.searchIndex == rhs.searchIndex
            && lhs.aiTags == rhs.aiTags
            && lhs.aiTitle == rhs.aiTitle
            && lhs.aiEnrichedAt == rhs.aiEnrichedAt
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.deletedAt == rhs.deletedAt
            && lhs.deviceOrigin == rhs.deviceOrigin
            && lhs.hasRichContent == rhs.hasRichContent
    }

    /// Rewrites a *server-fetched* record into a content-free tombstone: nil only marks a key
    /// changed when the record already held a value, which is what erases it under `.changedKeys`.
    /// Keys `item(from:)` requires stay populated, so every build still reads a valid deleted clip.
    static func applyTombstone(from item: ClipboardItem, to record: CKRecord) {
        record[Key.type] = item.type.rawValue
        record[Key.timestamp] = item.timestamp
        record[Key.modifiedAt] = item.modifiedAt
        record[Key.deletedAt] = item.deletedAt
        record[Key.sourceApp] = nil
        record[Key.textContent] = nil
        record[Key.textFilename] = nil
        record[Key.imageFilename] = nil
        record[Key.isPinned] = 0
        record[Key.isBookmarked] = 0
        record[Key.tags] = nil
        record[Key.ocrText] = nil
        record[Key.isTruncated] = 0
        record[Key.originalSizeBytes] = nil
        record[Key.searchIndex] = nil
        record[Key.aiTags] = nil
        record[Key.aiTitle] = nil
        record[Key.aiEnrichedAt] = nil
        record[Key.deviceOrigin] = nil
        record[Key.hasRichContent] = 0
        record[Key.blob] = nil
        // Empty data, not nil: a differing value always marks the key changed, so the old
        // encrypted copy is overwritten without relying on how nil behaves for encrypted keys.
        record.encryptedValues[Key.encContent] = Data()
    }

    private static func encryptedCopy(of record: CKRecord) -> Data? {
        guard let data = record.encryptedValues[Key.encContent] as? Data, !data.isEmpty else { return nil }
        return data
    }

    /// Classifies the encrypted copy of a live record against the record's own version stamp.
    static func encryptedCopyState(of record: CKRecord) -> EncryptedCopyState {
        guard let data = encryptedCopy(of: record) else { return .absent }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(EncryptedContentHeader.self, from: data) else {
            return .unreadable
        }
        guard header.version <= EncryptedContentPayload.currentVersion else { return .newerFormat }
        guard let payload = try? decoder.decode(EncryptedContentPayload.self, from: data) else {
            return .unreadable
        }
        guard let modifiedAt = record[Key.modifiedAt] as? Date else { return .stale }
        let difference = abs(payload.contentStamp - millisecondStamp(modifiedAt))
        return difference <= contentStampToleranceMilliseconds ? .current(payload) : .stale
    }

    /// Whether this device has to rewrite the record's encrypted copy. A payload from a newer
    /// format is not flagged, so builds with different formats never rewrite each other's copy.
    static func encryptedRefreshReason(for record: CKRecord) -> EncryptedRefreshReason? {
        if record[Key.deletedAt] as? Date != nil {
            return encryptedCopy(of: record) == nil ? nil : .tombstoneHoldsContent
        }
        switch encryptedCopyState(of: record) {
        case .absent: return .missing
        case .unreadable: return .unreadable
        case .stale: return .stale
        case .newerFormat, .current: return nil
        }
    }

    private static func plainContent(of record: CKRecord) -> SyncedContent {
        SyncedContent(
            sourceApp: record[Key.sourceApp] as? String,
            textContent: record[Key.textContent] as? String,
            ocrText: record[Key.ocrText] as? String,
            searchIndex: record[Key.searchIndex] as? String,
            tags: record[Key.tags] as? [String] ?? [],
            aiTags: record[Key.aiTags] as? [String] ?? [],
            aiTitle: record[Key.aiTitle] as? String
        )
    }

    /// Reads the clip content: the encrypted copy when it belongs to this version of the record,
    /// otherwise the plain fields. A tombstone is read from the plain fields whatever the
    /// encrypted field holds.
    private static func syncedContent(of record: CKRecord, isDeleted: Bool) -> SyncedContent {
        var content = plainContent(of: record)
        guard !isDeleted, case .current(let payload) = encryptedCopyState(of: record) else {
            return content
        }
        content.sourceApp = payload.sourceApp
        content.tags = payload.tags
        content.aiTags = payload.aiTags
        content.aiTitle = payload.aiTitle
        if !payload.plainFields.contains(Key.textContent) { content.textContent = payload.textContent }
        if !payload.plainFields.contains(Key.ocrText) { content.ocrText = payload.ocrText }
        if !payload.plainFields.contains(Key.searchIndex) { content.searchIndex = payload.searchIndex }
        return content
    }

    static func item(from record: CKRecord) -> ClipboardItem? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let typeRaw = record[Key.type] as? String,
              let type = ClipboardItemType(rawValue: typeRaw),
              let timestamp = record[Key.timestamp] as? Date,
              let modifiedAt = record[Key.modifiedAt] as? Date else { return nil }
        let rawTextFilename = record[Key.textFilename] as? String
        let rawImageFilename = record[Key.imageFilename] as? String
        guard let filenames = validatedBlobFilenames(
            type: type,
            textFilename: rawTextFilename,
            imageFilename: rawImageFilename
        ) else {
            return nil
        }
        let bool: (String) -> Bool = { ((record[$0] as? Int) ?? 0) != 0 }
        let deletedAt = record[Key.deletedAt] as? Date
        let content = syncedContent(of: record, isDeleted: deletedAt != nil)
        return ClipboardItem(
            id: id,
            type: type,
            timestamp: timestamp,
            sourceApp: content.sourceApp,
            textContent: content.textContent,
            textFilename: filenames.textFilename,
            imageFilename: filenames.imageFilename,
            hasRichContent: bool(Key.hasRichContent),
            isPinned: bool(Key.isPinned),
            isBookmarked: bool(Key.isBookmarked),
            tags: content.tags,
            ocrText: content.ocrText,
            isTruncated: bool(Key.isTruncated),
            originalSizeBytes: record[Key.originalSizeBytes] as? Int,
            searchIndex: content.searchIndex,
            aiTags: content.aiTags,
            aiTitle: content.aiTitle,
            aiEnrichedAt: record[Key.aiEnrichedAt] as? Date,
            modifiedAt: modifiedAt,
            deletedAt: deletedAt,
            deviceOrigin: record[Key.deviceOrigin] as? String ?? ""
        )
    }

    private static func validatedBlobFilenames(
        type: ClipboardItemType,
        textFilename: String?,
        imageFilename: String?
    ) -> (textFilename: String?, imageFilename: String?)? {
        guard textFilename == nil || imageFilename == nil else { return nil }

        if let textFilename {
            guard type == .text,
                  let reference = SyncBlobReference(filename: textFilename, kind: .text) else { return nil }
            return (reference.filename, nil)
        }

        if let imageFilename {
            guard type == .image,
                  let reference = SyncBlobReference(filename: imageFilename, kind: .image) else { return nil }
            return (nil, reference.filename)
        }

        return (nil, nil)
    }
}
