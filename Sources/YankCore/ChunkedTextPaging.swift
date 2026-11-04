import Foundation

/// Paging state for the detail view of a large text clip, shared by the macOS and iOS detail
/// models. Pure value: the model owns it on the main actor and a detached file read captures only
/// the `Request` values, never the struct. How a further page is triggered (scroll on macOS, a tap
/// on iOS) stays with each platform.
struct ChunkedTextPaging: Equatable, Sendable {
    /// Characters in the first page of a clip's text.
    static let firstPageCharCount = 2_000
    /// Characters in every page after the first.
    static let laterPageCharCount = 2_000

    /// What to read next. Captured by the file read and handed back to `apply`.
    struct Request: Equatable, Sendable {
        let itemID: UUID
        let byteOffset: Int
        let charCount: Int
    }

    private(set) var visibleText = ""
    private(set) var totalBytes = 0
    private(set) var loadedCharCount = 0
    private(set) var reachedEOF = true
    private(set) var isLoadingMore = false
    /// Where the next page starts in the file, so a page reads only its own bytes.
    private(set) var nextByteOffset = 0
    /// The clip these pages belong to, so a page that arrives after focus moved on is dropped.
    private(set) var itemID: UUID?

    var hasMore: Bool { !reachedEOF && loadedCharCount >= Self.firstPageCharCount }

    /// Starts over for a newly focused clip.
    mutating func begin(itemID: UUID) {
        self = ChunkedTextPaging()
        self.itemID = itemID
    }

    /// Shows text that is already in memory; there is nothing more to load.
    mutating func showInline(_ text: String) {
        visibleText = text
        reachedEOF = true
    }

    /// The read for the first page of the current clip, marking it as loading.
    mutating func firstRequest() -> Request? {
        guard let itemID else { return nil }
        isLoadingMore = true
        return Request(itemID: itemID, byteOffset: 0, charCount: Self.firstPageCharCount)
    }

    /// The read for the next page, or nil while a page is loading or the text is complete.
    mutating func nextRequest() -> Request? {
        guard let itemID, !isLoadingMore, hasMore else { return nil }
        isLoadingMore = true
        return Request(itemID: itemID, byteOffset: nextByteOffset, charCount: Self.laterPageCharCount)
    }

    /// Takes the result of a read. A page for another clip is ignored and leaves this clip's state
    /// alone (the new clip's `begin` already reset the loading flag). For the current clip the
    /// loading flag always clears; a page that no longer starts where the text ends, or a failed
    /// read (`nil`), adds nothing. The first page replaces, so two overlapping loads of the same
    /// clip cannot double it.
    mutating func apply(_ page: TextChunkPage?, for itemID: UUID, at byteOffset: Int) {
        guard itemID == self.itemID else { return }
        isLoadingMore = false
        guard byteOffset == nextByteOffset, let page else { return }
        if byteOffset == 0 {
            visibleText = page.text
            loadedCharCount = page.text.count
        } else {
            visibleText += page.text
            loadedCharCount += page.text.count
        }
        totalBytes = page.totalBytes
        reachedEOF = page.reachedEOF
        nextByteOffset = page.nextByteOffset
    }
}
