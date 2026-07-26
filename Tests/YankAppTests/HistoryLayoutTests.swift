import Testing
@testable import Yank

@Suite("History Layout")
struct HistoryLayoutTests {
    @Test("Split rail clamps between minimum and maximum")
    func splitRailClampsBetweenMinimumAndMaximum() {
        #expect(HistoryLayout.splitRailWidth(for: 300) == HistoryLayout.splitRailMinWidth)
        #expect(HistoryLayout.splitRailWidth(for: 2_000) == HistoryLayout.splitRailMaxWidth)
    }

    @Test("Gallery always uses two columns")
    func galleryAlwaysUsesTwoColumns() {
        #expect(HistoryLayout.tileColumnCount(viewMode: .gallery, streamWidth: 320, density: .snug) == 2)
        #expect(HistoryLayout.tileColumnCount(viewMode: .gallery, streamWidth: 1_200, density: .airy) == 2)
    }

    @Test("Grid and masonry derive columns from width and density")
    func gridAndMasonryDeriveColumnsFromWidthAndDensity() {
        #expect(HistoryLayout.tileColumnCount(viewMode: .grid, streamWidth: 360, density: .airy) == 1)
        #expect(HistoryLayout.tileColumnCount(viewMode: .masonry, streamWidth: 640, density: .snug) >= 4)
    }

    @Test("List and split use one navigation column")
    func listAndSplitUseOneNavigationColumn() {
        #expect(HistoryLayout.tileColumnCount(viewMode: .list, streamWidth: 1_200, density: .snug) == 1)
        #expect(HistoryLayout.tileColumnCount(viewMode: .split, streamWidth: 1_200, density: .snug) == 1)
    }

    @Test("History opening always scrolls to the first newest item")
    func openingScrollTargetIsFirstItem() {
        let newest = ClipboardItem.text("newest")
        let older = ClipboardItem.text("older")

        #expect(HistoryOpeningPosition.scrollTargetID(in: [newest, older]) == newest.id)
        #expect(HistoryOpeningPosition.scrollTargetID(in: []) == nil)
    }

    @Test("History opening selects the newest unpinned item while keeping the scroll at top")
    func openingSelectionPrefersNewestUnpinnedItem() {
        var pinned = ClipboardItem.text("pinned")
        pinned.isPinned = true
        let newestUnpinned = ClipboardItem.text("newest unpinned")
        let olderUnpinned = ClipboardItem.text("older unpinned")

        let items = [pinned, newestUnpinned, olderUnpinned]
        #expect(HistoryOpeningPosition.selectionID(in: items) == newestUnpinned.id)
        #expect(HistoryOpeningPosition.scrollTargetID(in: items) == pinned.id)
    }

    @Test("Masonry cache identity follows only the applied search query")
    func masonryCacheIdentityFollowsAppliedSearch() {
        let initial = HistoryContentView.MasonryKey(
            token: 1,
            columns: 3,
            debouncedSearch: "applied",
            tag: nil,
            isMasonry: true
        )
        let rawQueryChanged = HistoryContentView.MasonryKey(
            token: 1,
            columns: 3,
            debouncedSearch: "applied",
            tag: nil,
            isMasonry: true
        )
        let appliedQueryChanged = HistoryContentView.MasonryKey(
            token: 1,
            columns: 3,
            debouncedSearch: "updated",
            tag: nil,
            isMasonry: true
        )

        #expect(rawQueryChanged == initial)
        #expect(appliedQueryChanged != initial)
    }
}
