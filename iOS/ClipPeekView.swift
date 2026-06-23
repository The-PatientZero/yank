import SwiftUI

/// The long-press "peek" preview for a clip — a compact, read-only card the context
/// menu shows above its actions. The iOS analog of the Mac's Quick Look (Space-to-peek).
/// Content-aware via the shared `ClipKind`, so it previews exactly like the Mac.
struct ClipPeekView: View {
    let item: ClipboardItem
    let store: ClipStore

    @State private var image: UIImage?
    @State private var text = ""
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = IOSType.readingBody
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: ClipKind { item.kind }
    private var displayedText: String { text.isEmpty ? item.textContent ?? "" : text }
    private var metrics: ClipPeekMetrics { .contextMenu }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            preview
            footer
        }
        .padding(Space.lg)
        .frame(width: metrics.width)
        .background(Color.yankRaised, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .scaleEffect(image == nil && item.type == .image && !reduceMotion ? IOSMotion.cardScale : 1)
        .animation(IOSMotion.present(reduceMotion), value: image != nil)
        .task(id: item.id) { await loadPreview() }
    }

    @ViewBuilder private var preview: some View {
        switch kind {
        case let .color(color, raw):
            ClipSwatchPreview(color: color, raw: raw, cornerRadius: Radius.md)
                .frame(height: metrics.swatchHeight)
        case .image:
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: metrics.imageMaxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: metrics.imagePlaceholderMinHeight)
            }
        case let .link(url):
            VStack(alignment: .leading, spacing: Space.xs) {
                Label(url.host ?? url.absoluteString, systemImage: "link")
                    .font(.yank(.subheadline, weight: .semibold))
                Text(url.absoluteString)
                    .font(.yank(.caption)).foregroundStyle(.secondary)
                    .lineLimit(metrics.linkLineLimit).truncationMode(.middle)
            }
        case .code:
            Text(displayedText)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(metrics.textLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Text(displayedText)
                .font(.system(size: bodySize))
                .lineLimit(metrics.textLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.xs) {
            Text(kind.label).font(.yank(.caption2, weight: .medium)).foregroundStyle(Color.yankTextTertiary)
            ClipStatusBadge(item: item)
            if !item.tags.isEmpty {
                Text("#" + item.tags.joined(separator: " #"))
                    .font(.yank(.caption2)).foregroundStyle(.tint).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Text(item.relativeAge).font(.yank(.caption2)).foregroundStyle(Color.yankTextTertiary)
        }
    }

    private func loadPreview() async {
        image = nil
        text = ""
        if item.type == .image {
            image = await loadImage()
        } else {
            text = await loadText()
        }
    }

    private func loadImage() async -> UIImage? {
        guard let url = store.blobURL(for: item) else { return nil }
        let cgImage = await ThumbnailCache.shared.loadThumbnail(for: item.id, at: url, maxPixel: metrics.imageMaxPixel)
        return cgImage.map(UIImage.init)
    }

    private func loadText() async -> String {
        guard item.textFilename != nil else { return item.textContent ?? "" }
        let textURL = store.blobURL(for: item)
        let result = await Task.detached(priority: .userInitiated) {
            ClipStore.textChunk(for: item, textURL: textURL, charCount: 2_000)
        }.value
        return result?.text ?? item.textContent ?? ""
    }
}
