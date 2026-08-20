import SwiftUI

/// Renders a clip by kind (swatch/thumbnail/link/code) for Grid/Masonry/Gallery. Kept
/// separate from iOS `ClipTileView` on purpose — the font model (fixed vs Dynamic-Type)
/// and image type (`NSImage`/`UIImage`) differ; shared pieces live in `ClipKind` and the layout tokens.
struct ClipTile: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let mode: ClipViewMode
    let density: ClipDensity
    let isPrimarySelection: Bool
    let isMultiSelected: Bool
    var quickKey: Int? = nil
    var pastesOnClick = true

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: ClipKind { item.kind }
    private var isGallery: Bool { mode == .gallery }
    private var metrics: ClipTileMetrics { mode.tileMetrics(density: density) }
    // Naming inverts vs iOS `ClipTileView.emphasisRole`: here `.focused` is keyboard-primary
    // and `.selected` is multi-select; iOS uses the opposite vocabulary (`isSelected`/
    // `isHighlighted`). Same two roles — keep in sync if either changes.
    private var emphasisRole: ClipTileEmphasisRole {
        if isPrimarySelection { return .focused }
        if isMultiSelected { return .selected }
        return .none
    }
    private var liftRole: ClipTileLiftRole { isHovered ? .raised : .none }

    private var previewLines: Int { metrics.previewLines }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            preview
                .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(isGallery ? Space.lg : Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: metrics.fixedHeight, alignment: .top)
        .background(tileBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(borderColor, lineWidth: emphasisRole.metrics.borderWidth)
        )
        .overlay(alignment: .topTrailing) { quickKeyBadge }
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowYOffset)
        .scaleEffect(reduceMotion ? 1 : liftRole.metrics.scale)
        .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        .onHover { isHovered = $0 }
        .help(pastesOnClick ? "Click to paste" : "Double-click to paste")
        .animation(YankMotion.quick(reduceMotion), value: isHovered)
        .animation(YankMotion.state(reduceMotion), value: isPrimarySelection)
        .animation(YankMotion.state(reduceMotion), value: isMultiSelected)
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Color.yankRaised)
            .overlay {
                if isPrimarySelection {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(AppTheme.active.foreground.opacity(emphasisRole.metrics.fillOpacity))
                } else if isMultiSelected {
                    RoundedRectangle(cornerRadius: Radius.md)
                            .fill(Color.yankMultiSelect)
                }
            }
    }

    private var borderColor: Color {
        if isPrimarySelection { return AppTheme.active.foreground.opacity(emphasisRole.metrics.borderOpacity) }
        if isMultiSelected { return Color.yankMultiSelectBorder }
        return Color.yankHairline
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

    // MARK: - Preview (kind-specific)

    @ViewBuilder
    private var preview: some View {
        switch kind {
        case let .color(color, raw):
            ClipSwatchPreview(color: color, raw: raw)
                .frame(maxWidth: .infinity)
                .frame(minHeight: metrics.mediaMinHeight)
        case .image:
            thumbnail
        case let .link(url):
            linkPreview(url)
        case .code:
            codePreview
        default:
            textPreview
        }
    }

    private var thumbnail: some View {
        ClipThumbnail(item: item, store: store, contentMode: .fill, maxPixel: metrics.thumbnailMaxPixel)
            .frame(maxWidth: .infinity)
            .frame(minHeight: metrics.mediaMinHeight, maxHeight: metrics.thumbnailMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func linkPreview(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xs) {
                Image(systemName: "link")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundColor(AppTheme.active.foreground)
                    .accessibilityHidden(true)
                Text(url.host ?? url.absoluteString)
                    .font(.system(size: density.bodyFont, weight: .semibold))
                    .lineLimit(1)
            }
            Text(url.path.isEmpty ? url.absoluteString : url.path)
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.secondary)
                .lineLimit(previewLines - 1)
                .truncationMode(.middle)
        }
    }

    private var codePreview: some View {
        Text(item.textContent ?? "")
            .font(.system(size: density.bodyFont - 1, design: .monospaced))
            .lineLimit(previewLines)
            .foregroundColor(.yankCodeText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.sm)
            .background(Color.yankQuietFill, in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var textPreview: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: kind.glyph)
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.secondary)
                .padding(.top, Space.xxs)
                .accessibilityHidden(true)
            Text(item.excerpt)
                .font(.system(size: density.bodyFont))
                .lineLimit(previewLines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Space.xs) {
            Text(kind.label)
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundColor(.yankTextTertiary)
            RichContentBadge(state: item.richContentState)
            Spacer(minLength: 0)
            ClipStatusBadge(item: item)
            Text(item.relativeAge)
                .font(.system(size: TypeScale.micro))
                .foregroundColor(.yankTextTertiary)
        }
    }

    @ViewBuilder
    private var quickKeyBadge: some View {
        if let key = quickKey {
            QuickKeyBadge(key: key)
                .padding(Space.xs)
        }
    }
}

/// Renders an item's thumbnail: downsampled off disk, cached, and decoded off the main thread (see `ThumbnailCache`).
struct ClipThumbnail: View {
    let item: ClipboardItem
    let store: ClipboardStore
    var contentMode: ContentMode = .fill
    var maxPixel: Int = 240

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityLabel("Image clip")
            } else {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.yankPlaceholderFill)
                    .accessibilityLabel("Loading image")
            }
        }
        .task(id: item.id) {
            if image == nil, let url = store.blobURL(for: item) {
                image = await Self.load(id: item.id, url: url, maxPixel: maxPixel)
            }
        }
    }

    private static func load(id: UUID, url: URL, maxPixel: Int) async -> NSImage? {
        guard let cg = await ThumbnailCache.shared.loadThumbnail(for: id, at: url, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: .zero)   // .zero -> uses the CGImage's pixel size
    }
}
