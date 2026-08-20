import SwiftUI

/// iOS grid/gallery tile, visually mirroring macOS `ClipTile`; kind detection shared via `ClipKind`.
/// Kept separate rather than merged: divergent font model (Dynamic-Type `.yank` vs fixed
/// `TypeScale`) and image type (`UIImage` vs `NSImage`) — see macOS `ClipTile`'s note.
struct ClipTileView: View {
    let item: ClipboardItem
    let store: ClipStore
    let mode: ClipViewMode
    let density: ClipDensity
    var isHighlighted = false
    var isSelected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: ClipKind { item.kind }
    private var isGallery: Bool { mode == .gallery }
    private var metrics: ClipTileMetrics { mode.tileMetrics(density: density) }
    // Naming inverts the macOS twin (`ClipTile.emphasisRole`) on purpose: here `isHighlighted`→`.focused`,
    // `isSelected`→`.selected`; macOS maps `isPrimarySelection`→`.focused`, `isMultiSelected`→`.selected`.
    // Same two roles, opposite boolean vocabulary — keep both in sync if either changes.
    private var emphasisRole: ClipTileEmphasisRole {
        if isSelected { return .selected }
        if isHighlighted { return .focused }
        return .none
    }
    private var liftRole: ClipTileLiftRole { isHighlighted ? .raised : .none }

    private var previewLines: Int { metrics.previewLines }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            preview.frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(isGallery ? Space.lg : Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `minHeight` (not a fixed height) so a tile keeps its even baseline at normal sizes
        // but can grow at the accessibility text sizes instead of clipping a glyph. `nil`
        // height (masonry) stays intrinsic.
        .frame(minHeight: metrics.fixedHeight, alignment: .top)
        .background(tileBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(borderStyle, lineWidth: emphasisRole.metrics.borderWidth)
        )
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowYOffset)
        .scaleEffect(reduceMotion ? 1 : liftRole.metrics.scale)
        .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        .animation(IOSMotion.quick(reduceMotion), value: isHighlighted)
        .animation(IOSMotion.state(reduceMotion), value: isSelected)
    }

    /// Selection/focus share one wash — `emphasisRole.fillOpacity` is 0 for `.none`. Uses the
    /// environment `.tint` (chosen theme) to match the row and swipe actions, not the system accent.
    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Color.yankRaised)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(AnyShapeStyle(.tint).opacity(emphasisRole.metrics.fillOpacity))
            }
    }

    private var borderStyle: AnyShapeStyle {
        if isSelected || isHighlighted {
            return AnyShapeStyle(.tint.opacity(emphasisRole.metrics.borderOpacity))
        }
        return AnyShapeStyle(Color.yankHairline)
    }

    private var shadowOpacity: Double {
        max(emphasisRole.metrics.shadowOpacity, liftRole.metrics.shadowOpacity)
    }

    private var shadowRadius: CGFloat {
        liftRole == .raised ? liftRole.metrics.shadowRadius : ClipTileLiftRole.none.metrics.shadowRadius
    }

    private var shadowYOffset: CGFloat {
        liftRole == .raised ? liftRole.metrics.shadowYOffset : ClipTileLiftRole.none.metrics.shadowYOffset
    }

    @ViewBuilder private var preview: some View {
        switch kind {
        case let .color(color, raw):
            ClipSwatchPreview(color: color, raw: raw)
                .frame(maxWidth: .infinity)
                .frame(minHeight: metrics.mediaMinHeight)
        case .image:                 thumbnail
        case let .link(url):         linkPreview(url)
        case .code:                  codePreview
        default:                     textPreview
        }
    }

    private var thumbnail: some View {
        ClipThumbnailView(item: item, store: store, maxPixel: metrics.thumbnailMaxPixel)
            .frame(maxWidth: .infinity)
            .frame(minHeight: metrics.mediaMinHeight, maxHeight: metrics.thumbnailMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func linkPreview(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xs) {
                Image(systemName: "link").font(.yank(.caption, weight: .semibold)).foregroundStyle(.tint)
                Text(url.host ?? url.absoluteString).font(.yank(.subheadline, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(url.path.isEmpty ? url.absoluteString : url.path)
                .font(.yank(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(max(1, previewLines - 1))
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
        }
    }

    private var codePreview: some View {
        Text(item.textContent ?? "")
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(previewLines)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Color.yankCodeText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.sm)
            .background(Color.yankQuietFill, in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var textPreview: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: kind.glyph).font(.yank(.caption)).foregroundStyle(.secondary).padding(.top, Space.xxs)
            Text(item.excerpt)
                .font(.yank(.subheadline))
                .lineLimit(previewLines)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.xs) {
            Text(kind.label).font(.yank(.caption2, weight: .medium)).foregroundStyle(Color.yankTextTertiary)
            RichContentBadge(state: item.richContentState, font: .yank(.caption2))
            Spacer(minLength: 0)
            ClipStatusBadge(item: item)
            Text(item.relativeAge).font(.yank(.caption2)).foregroundStyle(Color.yankTextTertiary)
        }
    }
}
