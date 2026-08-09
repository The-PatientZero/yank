import SwiftUI

/// How the clip stream is laid out. Chosen in the header or Settings, remembered
/// across launches. Every mode renders the same content-aware clips — only the
/// arrangement changes, so the cards can morph from one mode to the next.
enum ClipViewMode: String, CaseIterable, Identifiable {
    case list, grid, masonry, gallery, split

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list:    return "List"
        case .grid:    return "Grid"
        case .masonry: return "Masonry"
        case .gallery: return "Gallery"
        case .split:   return "Split"
        }
    }

    /// Toolbar/segment glyph.
    var symbol: String {
        switch self {
        case .list:    return "list.bullet"
        case .grid:    return "square.grid.2x2"
        case .masonry: return "rectangle.3.offgrid"
        case .gallery: return "square.grid.2x2.fill"
        case .split:   return "rectangle.split.2x1"
        }
    }

    /// One-line, plain-English description (self-explaining UI).
    var blurb: String {
        switch self {
        case .list:    return "Dense rows — fastest to scan text."
        case .grid:    return "Even tiles — lots at a glance."
        case .masonry: return "Tiles sized to fit — nothing clipped."
        case .gallery: return "Big rich tiles — best for images."
        case .split:   return "A rail plus a live preview pane."
        }
    }

    /// Modes that arrange clips as tiles (vs. full-width rows).
    var isTiled: Bool {
        switch self {
        case .grid, .masonry, .gallery: return true
        case .list, .split:             return false
        }
    }

    static var platformCases: [ClipViewMode] {
        #if os(iOS)
        allCases.filter { $0 != .split }
        #else
        allCases
        #endif
    }
}

/// How much breathing room each clip gets. Orthogonal to the view mode.
enum ClipDensity: String, CaseIterable, Identifiable {
    case snug, cozy, airy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .snug: return "Snug"
        case .cozy: return "Cozy"
        case .airy: return "Airy"
        }
    }

    var blurb: String {
        switch self {
        case .snug: return "Fit the most clips."
        case .cozy: return "Balanced."
        case .airy: return "Roomy, easiest to read."
        }
    }

    /// Vertical padding inside a list/split row.
    var rowVerticalPadding: CGFloat {
        switch self {
        case .snug: return 4
        case .cozy: return 8
        case .airy: return 12
        }
    }

    /// Gap between stacked rows/tiles.
    var spacing: CGFloat {
        switch self {
        case .snug: return 2
        case .cozy: return 6
        case .airy: return 10
        }
    }

    /// Primary clip-text size on the fixed macOS scale, drawn from the shared `TypeScale`
    /// so the density ramp and the type system can't drift apart. (iOS sizes clip text from
    /// `IOSType.readingBody` instead — see `ClipRowView` — so its content stays at/above the
    /// system body and scales with Dynamic Type; this compact ramp is macOS-only.)
    var bodyFont: CGFloat {
        switch self {
        case .snug: return TypeScale.control  // 12
        case .cozy: return TypeScale.body     // 13
        case .airy: return TypeScale.input    // 14
        }
    }

    /// Lines of excerpt shown before truncating.
    var excerptLines: Int {
        switch self {
        case .snug: return 1
        case .cozy: return 2
        case .airy: return 3
        }
    }

    /// Minimum tile width for the grid/masonry layouts.
    var tileMinWidth: CGFloat {
        switch self {
        case .snug: return 116
        case .cozy: return 148
        case .airy: return 180
        }
    }
}

let clipRowCornerRadius: CGFloat = Radius.md

/// Shared size decisions for content-aware clip tiles. The platform views still own
/// fonts, colours, and image wrappers; these metrics keep their tile geometry aligned.
struct ClipTileMetrics: Equatable {
    let fixedHeight: CGFloat?
    let previewLines: Int
    let mediaMinHeight: CGFloat
    let thumbnailMaxHeight: CGFloat
    let thumbnailMaxPixel: Int
}

extension ClipViewMode {
    func tileMetrics(density: ClipDensity) -> ClipTileMetrics {
        ClipTileMetrics(
            fixedHeight: tileHeight(density: density),
            previewLines: tilePreviewLines(density: density),
            mediaMinHeight: isGalleryTile ? 96 : 46,
            thumbnailMaxHeight: isGalleryTile ? 120 : 64,
            thumbnailMaxPixel: 400
        )
    }

    private var isGalleryTile: Bool { self == .gallery }

    private func tileHeight(density: ClipDensity) -> CGFloat? {
        switch self {
        case .gallery:
            return density == .airy ? 184 : 156
        case .grid:
            return density == .snug ? 88 : (density == .airy ? 124 : 108)
        default:
            return nil
        }
    }

    private func tilePreviewLines(density: ClipDensity) -> Int {
        isGalleryTile ? (density == .airy ? 5 : 4) : density.excerptLines + 1
    }
}

/// Semantic emphasis applied to a tile. Platforms choose the colour source, while this
/// role owns the shared opacity/line/shadow weights so focus and selection don't drift.
enum ClipTileEmphasisRole: Equatable {
    case none
    case focused
    case selected

    var metrics: ClipTileEmphasisMetrics {
        switch self {
        case .none:
            return ClipTileEmphasisMetrics(fillOpacity: 0, borderOpacity: 1, borderWidth: Hairline.width, shadowOpacity: 0)
        case .focused:
            return ClipTileEmphasisMetrics(
                fillOpacity: 0.10,
                borderOpacity: 0.90,
                borderWidth: Stroke.focusRing,
                shadowOpacity: 0.07
            )
        case .selected:
            return ClipTileEmphasisMetrics(
                fillOpacity: 0.12,
                borderOpacity: 0.55,
                borderWidth: 1,
                shadowOpacity: 0.05
            )
        }
    }
}

struct ClipTileEmphasisMetrics: Equatable {
    let fillOpacity: Double
    let borderOpacity: Double
    let borderWidth: CGFloat
    let shadowOpacity: Double
}

/// Lift is the transient presentation layer: pointer hover on macOS, open-item highlight
/// on iPad. It can combine with an emphasis role without changing layout.
enum ClipTileLiftRole: Equatable {
    case none
    case raised

    var metrics: ClipTileLiftMetrics {
        switch self {
        case .none:
            return ClipTileLiftMetrics(scale: 1, shadowOpacity: 0, shadowRadius: 7, shadowYOffset: 2)
        case .raised:
            return ClipTileLiftMetrics(scale: 1.01, shadowOpacity: 0.10, shadowRadius: 10, shadowYOffset: 4)
        }
    }
}

struct ClipTileLiftMetrics: Equatable {
    let scale: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat
}

/// Compact preview-card sizing used by the iOS context-menu peek. Kept beside tile
/// metrics because it previews the same semantic clip content at a larger scale.
struct ClipPeekMetrics: Equatable {
    static let contextMenu = ClipPeekMetrics(
        width: 320,
        swatchHeight: 120,
        imageMaxHeight: 280,
        imagePlaceholderMinHeight: 160,
        linkLineLimit: 3,
        textLineLimit: 14,
        imageMaxPixel: 800
    )

    let width: CGFloat
    let swatchHeight: CGFloat
    let imageMaxHeight: CGFloat
    let imagePlaceholderMinHeight: CGFloat
    let linkLineLimit: Int
    let textLineLimit: Int
    let imageMaxPixel: Int
}
