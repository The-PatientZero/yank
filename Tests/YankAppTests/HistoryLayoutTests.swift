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
}
