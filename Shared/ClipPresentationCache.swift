import Foundation
import SwiftUI

/// A clip's derived presentation (`kind`, `excerpt`) — pure functions of its immutable
/// content, but expensive to recompute and read several times per row per render, so
/// they're memoised here.
final class ClipPresentation: @unchecked Sendable {
    let kind: ClipKind
    let excerpt: String

    init(kind: ClipKind, excerpt: String) {
        self.kind = kind
        self.excerpt = excerpt
    }
}

/// Memoises `ClipPresentation` keyed by the clip's stable id. An id's content never
/// changes (pin/tag/bookmark edits don't touch `textContent`), so an entry is never
/// stale. `NSCache` is thread-safe and self-evicting; the count limit is a backstop.
private final class ClipPresentationCacheStorage: @unchecked Sendable {
    private let cache: NSCache<NSUUID, ClipPresentation>

    init() {
        let cache = NSCache<NSUUID, ClipPresentation>()
        cache.countLimit = 2_000
        self.cache = cache
    }

    func presentation(for item: ClipboardItem) -> ClipPresentation {
        // NSCache is thread-safe per operation; concurrent misses at worst compute and set
        // twice — harmless since presentation() is pure (see ClipPresentation above).
        let key = item.id as NSUUID
        if let hit = cache.object(forKey: key) { return hit }
        let made = ClipPresentation(kind: item.computeKind(), excerpt: item.computeExcerpt())
        cache.setObject(made, forKey: key)
        return made
    }
}

enum ClipPresentationCache {
    private static let storage = ClipPresentationCacheStorage()

    static func presentation(for item: ClipboardItem) -> ClipPresentation {
        storage.presentation(for: item)
    }
}
