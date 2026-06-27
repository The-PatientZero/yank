import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Index text clips into Core Spotlight so they're searchable system-wide without
/// opening the app. Incremental: each pass indexes only the clips that are
/// new since the last pass and removes the ones that disappeared, instead of rebuilding
/// the whole set every time the history changes. State and the CSSearchableIndex calls
/// are confined to a private serial queue, so it's safe to call from any thread.
private final class SpotlightIndexStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thepatientzero.yank.spotlight", qos: .utility)
    private var indexedIDs: Set<String> = []
    private var debounced: DispatchWorkItem?

    func index(_ items: [ClipboardItem]) {
        let snapshot = items
        queue.async { self.reconcile(snapshot) }
    }

    func schedule(_ items: [ClipboardItem], delay: TimeInterval = 0.6) {
        let snapshot = items
        queue.async {
            self.debounced?.cancel()
            let work = DispatchWorkItem { self.reconcile(snapshot) }
            self.debounced = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Remove every Yank clip from the system index and forget what's been indexed.
    /// Used when the user turns Spotlight indexing off.
    func clear() {
        queue.async {
            self.debounced?.cancel()
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["yank.clips"])
            self.indexedIDs = []
        }
    }

    private func reconcile(_ items: [ClipboardItem]) {
        let textItems = items.filter { ($0.textContent?.isEmpty == false) }
        let currentIDs = Set(textItems.map { $0.id.uuidString })

        let added = textItems.filter { !indexedIDs.contains($0.id.uuidString) }
        let removed = indexedIDs.subtracting(currentIDs)

        let index = CSSearchableIndex.default()
        if !added.isEmpty { index.indexSearchableItems(added.map(searchableItem)) }
        if !removed.isEmpty { index.deleteSearchableItems(withIdentifiers: Array(removed)) }
        indexedIDs = currentIDs
    }

    private func searchableItem(for item: ClipboardItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        // Index only a short first-line snippet, never the full clip body: a distinguishable title
        // in results and a bounded lock-screen / Spotlight preview rather than the whole (possibly
        // sensitive) content. Indexing is opt-in and off by default.
        let snippet = Self.snippet(from: item.textContent ?? "")
        attributes.title = snippet.isEmpty ? "Yank clip" : snippet
        attributes.contentDescription = snippet
        return CSSearchableItem(
            uniqueIdentifier: item.id.uuidString,
            domainIdentifier: "yank.clips",
            attributeSet: attributes
        )
    }

    /// First non-empty line, trimmed and length-capped — what's safe to expose to the system index.
    private static func snippet(from text: String, limit: Int = 100) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(limit))
    }
}

enum SpotlightIndexer {
    private static let storage = SpotlightIndexStorage()

    /// Index immediately (incrementally). Use when the caller already coalesces calls,
    /// or for the one-shot pass on launch.
    static func index(_ items: [ClipboardItem]) {
        storage.index(items)
    }

    /// Debounced incremental index — coalesces a burst of changes (captures, a sync
    /// landing many clips) into a single reconcile. Use from per-change hooks.
    static func schedule(_ items: [ClipboardItem], delay: TimeInterval = 0.6) {
        storage.schedule(items, delay: delay)
    }

    /// Purge every Yank clip from the system index (when the user disables indexing).
    static func clear() {
        storage.clear()
    }
}
