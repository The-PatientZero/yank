import Foundation
import SwiftUI

/// A clip's derived presentation — its inferred `kind` and its display `excerpt`. Both
/// are pure functions of the clip's immutable `type`/`textContent`, yet each is read
/// several times per row on every SwiftUI body pass (the kind drives the icon, the
/// preview, and the type label). Computing them is non-trivial (content sniffing +
/// whitespace collapse), so they're memoised here.
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
        // NSCache is thread-safe per operation, so no external lock is needed. Two threads
        // racing the same id at worst both compute and set — harmless, since the result is a
        // pure function of the clip's immutable content.
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
