import CoreGraphics

enum HistoryLayout {
    static let minWidth: CGFloat = 360
    static let minHeight: CGFloat = 480
    static let splitRailMinWidth: CGFloat = 188
    static let splitRailMaxWidth: CGFloat = 270
    static let splitRailRatio: CGFloat = 0.36

    static func splitRailWidth(for streamWidth: CGFloat) -> CGFloat {
        min(
            splitRailMaxWidth,
            max(splitRailMinWidth, streamWidth * splitRailRatio)
        )
    }

    static func tileColumnCount(viewMode: ClipViewMode, streamWidth: CGFloat, density: ClipDensity) -> Int {
        switch viewMode {
        case .gallery:
            return 2
        case .grid, .masonry:
            let availableWidth = streamWidth - 2 * Space.lg + density.spacing
            return max(1, Int(availableWidth / (density.tileMinWidth + density.spacing)))
        case .list, .split:
            return 1
        }
    }
}
