import Foundation

/// One on-device enrichment pass over a clip's text. New enrichment produces topic tags only;
/// `title` remains for source compatibility with the original 1.0 API and is ignored by Yank.
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
    /// Legacy 1.0 title threshold retained for source compatibility. Yank no longer calls it.
    public static let titleMinLength = 200

    /// Whether a freshly captured clip should be enriched now.
    public static func shouldEnrich(_ item: ClipboardItem, enabled: Bool) -> Bool {
        enabled
            && item.type == .text
            && !item.isTruncated
            && item.aiEnrichedAt == nil
            && (item.textContent?.count ?? 0) >= minTextLength
    }

    /// Legacy 1.0 title policy retained for source compatibility. Yank no longer calls it.
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

    /// The shared tag rule — see `TagNormalization`. Kept as a name here because the cleaner's
    /// own vectors read against it.
    static func normalize(_ input: String) -> String {
        TagNormalization.normalize(input)
    }
}

/// Legacy 1.0 title cleanup retained for source compatibility. Yank no longer calls it.
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
