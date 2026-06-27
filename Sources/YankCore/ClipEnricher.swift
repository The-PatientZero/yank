import Foundation

/// One on-device enrichment pass over a clip's text: a few topic tags plus an optional
/// one-line title (only worthwhile for long clips).
public struct ClipEnrichment: Sendable, Equatable {
    public var tags: [String]
    public var title: String?
    public init(tags: [String] = [], title: String? = nil) {
        self.tags = tags
        self.title = title
    }
}

/// Produces on-device suggestions for a clip's text. Implemented by the Foundation Models
/// enricher on macOS 26+; the protocol stays here (no framework import) so the pipeline and
/// tests don't depend on a platform-only framework.
public protocol ClipEnricher: Sendable {
    func enrich(_ text: String) async -> ClipEnrichment
}

/// Pure gating policy for background enrichment, extracted so the privacy/correctness rules
/// (opt-in, text-only, skip-truncated, skip-already-enriched, length thresholds) are tested
/// headlessly rather than living inside the `@MainActor` service wiring.
public enum ClipEnrichmentPolicy {
    /// Shortest text worth tagging at all.
    public static let minTextLength = 6
    /// Below this the excerpt already makes a fine title, so don't generate one.
    public static let titleMinLength = 200

    /// Whether a freshly captured clip should be enriched now.
    public static func shouldEnrich(_ item: ClipboardItem, enabled: Bool) -> Bool {
        enabled
            && item.type == .text
            && !item.isTruncated
            && item.aiEnrichedAt == nil
            && (item.textContent?.count ?? 0) >= minTextLength
    }

    /// Whether a clip of `textCount` characters is long enough to warrant a generated title.
    public static func shouldGenerateTitle(textCount: Int) -> Bool {
        textCount >= titleMinLength
    }
}

/// Pure cleanup for raw tag output: normalise to the tag idiom, drop noise and anything the
/// user already tagged, dedupe, and cap. Shared by the enricher and tested headlessly.
public enum AITagCleaner {
    public static func clean(_ raw: [String], existing: [String] = [], limit: Int = 3) -> [String] {
        let taken = Set(existing.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for candidate in raw {
            let tag = normalize(candidate)
            guard tag.count >= 2, !taken.contains(tag), seen.insert(tag).inserted else { continue }
            out.append(tag)
            if out.count == limit { break }
        }
        return out
    }

    /// lowercase → spaces to dashes → keep letters/digits/dash → trim dashes → cap length.
    static func normalize(_ input: String) -> String {
        let dashed = input.lowercased().replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        let filtered = dashed.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(24))
    }
}

/// Pure cleanup for a generated title: collapse to one trimmed line, cap length, and drop it
/// when it's too short to be a useful label.
public enum AITitleCleaner {
    public static func clean(_ raw: String?, limit: Int = 80) -> String? {
        guard let raw else { return nil }
        let oneLine = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count >= 4 else { return nil }
        return String(oneLine.prefix(limit))
    }
}
