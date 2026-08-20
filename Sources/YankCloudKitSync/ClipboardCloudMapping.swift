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
        if let blobURL {
            record[Key.blob] = CKAsset(fileURL: blobURL)
        }
        return record
    }

    /// Whether two same-ID items would produce identical records — `ClipboardItem`'s own
    /// equality is identity-only, so the sync engine needs a field-wise check to tell "the
    /// zone already holds this version" apart from "a merge grafted local fields the zone
    /// lacks". Compares exactly the fields `record(from:)` writes; local-only state
    /// (`richFilename`) deliberately stays out.
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

    /// Rewrites a record *fetched from the server* into a content-free tombstone. Assigning
    /// `nil` marks a key changed only on a record that already holds a value for it, so this
    /// is the one shape of save that actually erases the clip's text, metadata, and asset
    /// from the zone under the `.changedKeys` policy. The keys `item(from:)` requires
    /// (`type`, `timestamp`, `modifiedAt`) stay populated, so every build still reads the
    /// result as a valid deleted clip.
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
        return ClipboardItem(
            id: id,
            type: type,
            timestamp: timestamp,
            sourceApp: record[Key.sourceApp] as? String,
            textContent: record[Key.textContent] as? String,
            textFilename: filenames.textFilename,
            imageFilename: filenames.imageFilename,
            hasRichContent: bool(Key.hasRichContent),
            isPinned: bool(Key.isPinned),
            isBookmarked: bool(Key.isBookmarked),
            tags: record[Key.tags] as? [String] ?? [],
            ocrText: record[Key.ocrText] as? String,
            isTruncated: bool(Key.isTruncated),
            originalSizeBytes: record[Key.originalSizeBytes] as? Int,
            searchIndex: record[Key.searchIndex] as? String,
            aiTags: record[Key.aiTags] as? [String] ?? [],
            aiTitle: record[Key.aiTitle] as? String,
            aiEnrichedAt: record[Key.aiEnrichedAt] as? Date,
            modifiedAt: modifiedAt,
            deletedAt: record[Key.deletedAt] as? Date,
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
