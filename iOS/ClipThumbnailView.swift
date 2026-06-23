import SwiftUI

/// Renders an image clip's thumbnail — downsampled straight off disk and cached, off
/// the main thread (see `ThumbnailCache`), the iOS counterpart to the macOS
/// `ClipThumbnail`. The blob syncs down from the Mac into the App Group.
struct ClipThumbnailView: View {
    let item: ClipboardItem
    let store: ClipStore
    var contentMode: ContentMode = .fill
    var maxPixel: Int = 400

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityLabel("Image thumbnail")
            } else {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.yankPlaceholderFill)
                    .accessibilityLabel("Loading image thumbnail")
            }
        }
        .task(id: item.id) {
            if image == nil, let url = store.blobURL(for: item) {
                image = await Self.load(id: item.id, url: url, maxPixel: maxPixel)
            }
        }
    }

    private static func load(id: UUID, url: URL, maxPixel: Int) async -> UIImage? {
        guard let cg = await ThumbnailCache.shared.loadThumbnail(for: id, at: url, maxPixel: maxPixel) else { return nil }
        return UIImage(cgImage: cg)
    }
}
