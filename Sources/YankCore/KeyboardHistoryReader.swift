import Foundation

/// Read-only keyboard view assembled from the host's bounded projection plus the small previews
/// of short texts that are queued but not yet imported. The memory-constrained keyboard never
/// scans or decodes the pending queue itself: it reads only the preview files, and only checks
/// that the queue entry a preview belongs to still exists.
struct KeyboardHistoryReader: Sendable {
    /// At most this many of the newest previews are read.
    static let maxLoadedPreviews = 10

    let projectionURL: URL
    let previewsURL: URL?
    let inboxEntriesURL: URL?
    private let reportSkippedPreviews: (@Sendable (Int) -> Void)?

    /// `previewsURL` and `inboxEntriesURL` are both needed to include pending previews.
    /// `reportSkippedPreviews` receives the number of preview files that could not be used, so the
    /// caller can log them; a bad preview never fails `load()`.
    init(
        projectionURL: URL,
        previewsURL: URL? = nil,
        inboxEntriesURL: URL? = nil,
        reportSkippedPreviews: (@Sendable (Int) -> Void)? = nil
    ) {
        self.projectionURL = projectionURL
        self.previewsURL = previewsURL
        self.inboxEntriesURL = inboxEntriesURL
        self.reportSkippedPreviews = reportSkippedPreviews
    }

    func load() throws -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        if FileManager.default.fileExists(atPath: projectionURL.path) {
            items = try KeyboardHistoryProjection.load(from: projectionURL).items
        }
        guard let previewsURL, let inboxEntriesURL else { return items }
        return merging(pendingPreviews(in: previewsURL, entriesURL: inboxEntriesURL), into: items)
    }

    /// Newest first. A preview is kept only while its queue entry exists and its text differs from
    /// every other kept preview.
    private func pendingPreviews(in previewsURL: URL, entriesURL: URL) -> [ClipboardItem] {
        let candidates: [(url: URL, entryID: UUID)]
        do {
            candidates = try ShareCaptureInbox.newestPreviewURLs(in: previewsURL, limit: Self.maxLoadedPreviews)
        } catch {
            reportSkippedPreviews?(1)
            return []
        }
        var previews: [ClipboardItem] = []
        var skipped = 0
        for candidate in candidates {
            let entryURL = ShareCaptureInbox.entryFileURL(for: candidate.entryID, in: entriesURL)
            // A preview whose entry is gone was imported (or is waiting for a sweep): not an error.
            guard FileManager.default.fileExists(atPath: entryURL.path) else { continue }
            guard let item = try? KeyboardHistoryProjection.load(
                from: candidate.url,
                maxEncodedBytes: ShareCaptureInbox.maxPreviewFileBytes
            ).items.first else {
                skipped += 1
                continue
            }
            previews.append(item)
        }
        if skipped > 0 { reportSkippedPreviews?(skipped) }
        return previews
    }

    /// Inserts each preview before the first item that is older, which keeps the projection's own
    /// order. Text already complete in the projection (byte-for-byte, the Text Capture Identity
    /// rule) or already in an earlier preview is dropped: a re-shared text has a new entry ID, so
    /// the ID alone cannot tell.
    private func merging(_ previews: [ClipboardItem], into items: [ClipboardItem]) -> [ClipboardItem] {
        var merged = items
        var knownTexts = items.compactMap { $0.holdsOnlyPreview ? nil : $0.textContent }
        for preview in previews {
            guard let text = preview.textContent,
                  !knownTexts.contains(where: { $0.utf8.elementsEqual(text.utf8) }) else { continue }
            knownTexts.append(text)
            let index = merged.firstIndex { $0.timestamp < preview.timestamp } ?? merged.endIndex
            merged.insert(preview, at: index)
        }
        return merged
    }
}
