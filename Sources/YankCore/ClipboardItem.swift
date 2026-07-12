import Foundation

/// Persisted clipboard-history record. Small text stays inline; large text and images
/// point at blob files. Rich pasteboard archives are macOS-local and not synced.
public struct ClipboardItem: Identifiable, Codable, Hashable, Sendable {
    /// Availability of a rich pasteboard archive for this clip on the current device.
    public enum RichContentState: Equatable, Sendable {
        /// This clip never had rich pasteboard content.
        case none
        /// The rich archive exists locally and can be replayed on paste.
        case availableLocally
        /// Another device recorded rich content, but the local-only archive is unavailable here.
        case unavailableOnThisDevice
    }

    /// Stable item identity, shared across sync replicas.
    public let id: UUID
    /// Primary content kind used for display, storage, and sync blob routing.
    public let type: ClipboardItemType
    /// Capture timestamp used for chronological ordering and sectioning.
    public let timestamp: Date
    /// Display name of the app observed during capture, if known.
    public let sourceApp: String?

    /// Inline text content for text clips; nil when large text is stored in a blob.
    public let textContent: String?

    /// Blob filename for large text clips.
    public let textFilename: String?

    /// Blob filename for image clips.
    public let imageFilename: String?

    /// Filename of the local rich pasteboard archive, replayed verbatim on paste.
    /// Rich archives are macOS-local and not synced.
    public var richFilename: String?

    /// Whether this clip had rich content when captured, even if the archive is unavailable here.
    public var hasRichContent: Bool = false

    /// Pin state; pinned clips are protected from retention and float to the top.
    public var isPinned: Bool = false

    /// Bookmark state; bookmarked clips are protected but stay in chronological position.
    public var isBookmarked: Bool = false

    /// User-defined tags attached to the clip.
    public var tags: [String] = []

    /// Extracted OCR text, persisted after first extraction.
    public var ocrText: String?

    /// On-device AI tag suggestions. Advisory and subordinate to user `tags`: they don't
    /// protect from retention and stay in their own field so they never pollute the user's
    /// namespace. `aiEnrichedAt` records when enrichment ran and guards re-running.
    public var aiTags: [String] = []
    /// Legacy on-device title retained only to decode and sync records from older releases.
    /// Yank no longer generates, displays, or searches this metadata.
    // TODO(v2): Remove aiTitle, the legacy title enrichment APIs, CloudKit mapping, and
    // compatibility tests together in the next breaking history/sync migration.
    public var aiTitle: String?
    public var aiEnrichedAt: Date?

    /// True when the original text exceeded the storage limit and only a preview is saved.
    public let isTruncated: Bool

    /// Original text size in bytes for large or truncated text clips.
    public let originalSizeBytes: Int?

    /// Compact keyword index for file-backed text clips, so search does not need to read
    /// multi-MB blobs on every keystroke.
    public let searchIndex: String?

    /// Last-writer-wins sync clock.
    public var modifiedAt: Date
    /// Soft-delete tombstone timestamp; non-nil means the delete should propagate.
    public var deletedAt: Date?
    /// Device identifier that last authored this record.
    public var deviceOrigin: String

    public init(id: UUID = UUID(), type: ClipboardItemType, timestamp: Date = Date(), sourceApp: String? = nil, textContent: String? = nil, textFilename: String? = nil, imageFilename: String? = nil, richFilename: String? = nil, hasRichContent: Bool = false, isPinned: Bool = false, isBookmarked: Bool = false, tags: [String] = [], ocrText: String? = nil, isTruncated: Bool = false, originalSizeBytes: Int? = nil, searchIndex: String? = nil, aiTags: [String] = [], aiTitle: String? = nil, aiEnrichedAt: Date? = nil, modifiedAt: Date? = nil, deletedAt: Date? = nil, deviceOrigin: String = "") {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.textContent = textContent
        self.textFilename = textFilename
        self.imageFilename = imageFilename
        self.richFilename = richFilename
        self.hasRichContent = hasRichContent
        self.isPinned = isPinned
        self.isBookmarked = isBookmarked
        self.tags = tags
        self.ocrText = ocrText
        self.isTruncated = isTruncated
        self.originalSizeBytes = originalSizeBytes
        self.searchIndex = searchIndex
        self.aiTags = aiTags
        self.aiTitle = aiTitle
        self.aiEnrichedAt = aiEnrichedAt
        self.modifiedAt = modifiedAt ?? timestamp
        self.deletedAt = deletedAt
        self.deviceOrigin = deviceOrigin
    }

    enum CodingKeys: String, CodingKey {
        case id, type, timestamp, sourceApp, textContent, textFilename, imageFilename, richFilename
        case isPinned, isBookmarked, tags, ocrText, isTruncated, originalSizeBytes, searchIndex
        case modifiedAt, deletedAt, deviceOrigin
        case hasRichContent
        case aiTags, aiTitle, aiEnrichedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.type = try container.decode(ClipboardItemType.self, forKey: .type)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        self.textContent = try container.decodeIfPresent(String.self, forKey: .textContent)
        self.textFilename = try container.decodeIfPresent(String.self, forKey: .textFilename)
        self.imageFilename = try container.decodeIfPresent(String.self, forKey: .imageFilename)
        self.richFilename = try container.decodeIfPresent(String.self, forKey: .richFilename)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        self.isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        self.originalSizeBytes = try container.decodeIfPresent(Int.self, forKey: .originalSizeBytes)
        self.searchIndex = try container.decodeIfPresent(String.self, forKey: .searchIndex)
        self.modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? self.timestamp
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.deviceOrigin = try container.decodeIfPresent(String.self, forKey: .deviceOrigin) ?? ""
        self.hasRichContent = try container.decodeIfPresent(Bool.self, forKey: .hasRichContent) ?? false
        self.aiTags = try container.decodeIfPresent([String].self, forKey: .aiTags) ?? []
        self.aiTitle = try container.decodeIfPresent(String.self, forKey: .aiTitle)
        self.aiEnrichedAt = try container.decodeIfPresent(Date.self, forKey: .aiEnrichedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encodeIfPresent(textContent, forKey: .textContent)
        try container.encodeIfPresent(textFilename, forKey: .textFilename)
        try container.encodeIfPresent(imageFilename, forKey: .imageFilename)
        try container.encodeIfPresent(richFilename, forKey: .richFilename)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isBookmarked, forKey: .isBookmarked)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(ocrText, forKey: .ocrText)
        try container.encode(isTruncated, forKey: .isTruncated)
        try container.encodeIfPresent(originalSizeBytes, forKey: .originalSizeBytes)
        try container.encodeIfPresent(searchIndex, forKey: .searchIndex)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(deviceOrigin, forKey: .deviceOrigin)
        try container.encode(hasRichContent, forKey: .hasRichContent)
        try container.encode(aiTags, forKey: .aiTags)
        try container.encodeIfPresent(aiTitle, forKey: .aiTitle)
        try container.encodeIfPresent(aiEnrichedAt, forKey: .aiEnrichedAt)
    }

    /// Create an inline text clip.
    public static func text(_ content: String, sourceApp: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            sourceApp: sourceApp,
            textContent: content
        )
    }

    /// Create an image clip backed by a blob filename.
    public static func image(filename: String, sourceApp: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .image,
            sourceApp: sourceApp,
            imageFilename: filename
        )
    }

    /// Create a text clip whose full content is stored in a blob and represented inline by a preview.
    public static func largeText(
        preview: String,
        filename: String,
        sourceApp: String? = nil,
        originalSizeBytes: Int? = nil,
        searchIndex: String? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            sourceApp: sourceApp,
            textContent: preview,
            textFilename: filename,
            originalSizeBytes: originalSizeBytes,
            searchIndex: searchIndex
        )
    }

    /// Create a text clip that stores only a preview because the original content exceeded limits.
    public static func truncatedText(preview: String, originalSizeBytes: Int, sourceApp: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            sourceApp: sourceApp,
            textContent: preview,
            isTruncated: true,
            originalSizeBytes: originalSizeBytes
        )
    }

    /// Whether the full text content lives in a blob file.
    public var isFileBacked: Bool {
        textFilename != nil
    }

    /// Rich-content availability for the current device.
    public var richContentState: RichContentState {
        if richFilename != nil { return .availableLocally }
        if hasRichContent { return .unavailableOnThisDevice }
        return .none
    }

    /// Soft-deleted (tombstone) — retained so the deletion can propagate via sync.
    public var isDeleted: Bool {
        deletedAt != nil
    }

    /// Protected from automatic eviction and age-based retention: pinned, bookmarked,
    /// or tagged. The single source of truth for this rule — retention and the store's
    /// overflow trimming both read it so the policy can never drift between them.
    public var isProtected: Bool {
        isPinned || isBookmarked || !tags.isEmpty
    }

    /// Case-insensitive search match across text content and extracted OCR text.
    public func matches(_ query: String) -> Bool {
        if textContent?.localizedCaseInsensitiveContains(query) == true { return true }
        if ClipboardSearchIndex.matches(searchIndex, query: query) { return true }
        if ocrText?.localizedCaseInsensitiveContains(query) == true { return true }
        if aiTags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        return false
    }

    /// Compact relative age for list display, e.g. "now", "2m", "3h", "5d", "2w".
    public func age(asOf now: Date) -> String {
        let interval = now.timeIntervalSince(timestamp)
        switch interval {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(interval / 60))m"
        case ..<86_400: return "\(Int(interval / 3_600))h"
        case ..<604_800: return "\(Int(interval / 86_400))d"
        default: return "\(Int(interval / 604_800))w"
        }
    }

    /// Compact relative age using the current time.
    public var relativeAge: String { age(asOf: Date()) }

    /// Flat spoken summary for custom clip cells. Callers pass their cached presentation
    /// label/excerpt so accessibility wording stays shared without recomputing UI kind data.
    public func accessibilityDescription(kindLabel: String, excerpt: String, asOf now: Date = Date()) -> String {
        var parts = [kindLabel, excerpt]
        if isPinned {
            parts.append("pinned")
        } else if isBookmarked {
            parts.append("bookmarked")
        }
        if !tags.isEmpty {
            parts.append("tags: " + tags.joined(separator: ", "))
        }
        parts.append(age(asOf: now))
        return parts.joined(separator: ", ")
    }

    /// Section label for date grouping: "Today", "Yesterday", or an abbreviated date.
    public func dayGroupLabel(asOf now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(timestamp, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(timestamp, inSameDayAs: yesterday) { return "Yesterday" }
        // `Date.FormatStyle` is a Sendable value type the system caches internally, avoiding
        // a fresh `DateFormatter` allocation for every dated section header on every list render.
        return timestamp.formatted(date: .abbreviated, time: .omitted)
    }

    /// Short display text for list and grid previews.
    public var previewText: String {
        switch type {
        case .text:
            let text = textContent ?? ""
            if text.count > 200 {
                return String(text.prefix(200)) + "…"
            }
            return text
        case .image:
            return "Image"
        }
    }

    public static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Primary kind of content stored in a clipboard item.
public enum ClipboardItemType: String, Codable, Sendable {
    case text
    case image
}
