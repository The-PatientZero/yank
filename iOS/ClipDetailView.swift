import SwiftUI

/// The iOS clip detail: full text or image, extracted (OCR) text, tags, and the
/// pin / bookmark / copy / delete actions — bringing the Mac's detail pane to iOS.
struct ClipDetailView: View {
    let item: ClipboardItem
    var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var model: ClipDetailContentModel
    @State private var localOCR: String?
    @State private var isExtracting = false
    @State private var newTag = ""
    @State private var copied = false
    @State private var tagSuggestions: [String] = []

    /// Clip content reads a touch larger than the stock body, still scaling with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = IOSType.readingBody

    init(item: ClipboardItem, store: ClipStore) {
        self.item = item
        self.store = store
        _model = State(wrappedValue: ClipDetailContentModel(store: store))
    }

    /// Re-read from the store so pin/bookmark/tag toggles reflect immediately.
    private var current: ClipboardItem { store.items.first { $0.id == item.id } ?? item }
    private var ocrText: String? { current.ocrText ?? localOCR }
    private var canExtract: Bool { current.type == .image && model.previewImage != nil && ocrText == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                sizeHeader
                content
                if current.richContentState != .none {
                    richContentNote
                }
                if let ocr = ocrText { ocrSection(ocr) }
                tagSection
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(current.kind.label.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { copyBar }
        .animation(IOSMotion.state(reduceMotion), value: copied)
        .animation(IOSMotion.state(reduceMotion), value: isExtracting)
        .animation(IOSMotion.state(reduceMotion), value: ocrText)
        .animation(IOSMotion.present(reduceMotion), value: model.previewImage != nil)
        .task(id: item.id) { await model.load(current) }
    }

    @ViewBuilder private var sizeHeader: some View {
        if current.isFileBacked || (current.type == .image && model.itemSize != nil) {
            HStack(spacing: Space.sm) {
                if current.isFileBacked {
                    Text("Large")
                        .font(.yank(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, Space.xxs)
                        .background(Color.yankOversize, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .accessibilityLabel("Large clip")
                }
                if let size = model.itemSize, size > 0 {
                    Text(model.formattedBytes(size))
                        .font(.yank(.caption2))
                        .foregroundStyle(Color.yankTextTertiary)
                }
            }
        }
    }

    private var richContentNote: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: current.richContentState == .availableLocally ? "wand.and.stars.inverse" : "wand.and.stars")
                .font(.yank(.caption))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(richContentNoteText)
                .font(.yank(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(Color.yankRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(richContentNoteText)
    }

    private var richContentNoteText: String {
        switch current.richContentState {
        case .none:
            ""
        case .availableLocally:
            "Formatting is preserved when pasted from this device."
        case .unavailableOnThisDevice:
            "This clip included formatting when captured. Plain content is available here."
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch current.type {
        case .text:
            VStack(alignment: .leading, spacing: Space.md) {
                Text(model.visibleText)
                    .font(.system(size: bodySize, design: current.kind.isCode ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if current.isTruncated {
                    truncationNote
                } else if model.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading more text")
                } else if model.hasMore {
                    Button {
                        Task { await model.loadNextChunk(current) }
                    } label: {
                        Text("— \(model.formattedBytes(model.totalBytes)) total · load more —")
                            .font(.yank(.caption))
                            .foregroundStyle(Color.yankTextTertiary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, Space.sm)
                }
            }
        case .image:
            if let previewImage = model.previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .accessibilityLabel(current.imageAccessibilityLabel)
            } else {
                imagePlaceholder
            }
        }
    }

    private var truncationNote: some View {
        Label(
            "Content was too large to store (\(model.formattedBytes(current.originalSizeBytes ?? 0))). Showing the start only.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.yank(.caption))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Color.yankSubtleFill)
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: bodySize, weight: .light))
                    .foregroundStyle(Color.yankTextTertiary)
            )
            .redacted(reason: .placeholder)
            .accessibilityLabel("Loading image preview")
    }

    private func ocrSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label("Extracted text", systemImage: "text.viewfinder")
                .font(.yank(.caption))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: bodySize))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.md)
        .background(Color.yankRaised.opacity(0.72), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !current.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(current.tags, id: \.self) { tag in
                            TagChip(label: tag, onRemove: { store.removeTag(tag, from: current) })
                        }
                    }
                }
            }
            HStack(spacing: Space.sm) {
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: newTag) { _, value in
                        tagSuggestions = TagSuggestions.matching(searchText: value, in: store.allTags)
                            .filter { !current.tags.contains($0) }
                    }
                    .onSubmit(addTag)
                Button("Add", action: addTag)
                    .disabled(TagChip.normalize(newTag).isEmpty)
            }
            if !tagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(tagSuggestions, id: \.self) { tag in
                            TagChip(label: tag, displayPrefix: "#", onTap: {
                                store.addTag(tag, to: current)
                                newTag = ""
                                tagSuggestions = []
                            })
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(IOSMotion.state(reduceMotion), value: current.tags)
        .animation(IOSMotion.quick(reduceMotion), value: tagSuggestions.isEmpty)
    }

    // MARK: - Toolbar / actions

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                store.togglePin(current)
            } label: {
                Image(systemName: current.isPinned ? "pin.fill" : "pin")
            }
            .accessibilityLabel(current.isPinned ? "Unpin" : "Pin to top")

            Button {
                store.toggleBookmark(current)
            } label: {
                Image(systemName: current.isBookmarked ? "bookmark.fill" : "bookmark")
            }
            .accessibilityLabel(current.isBookmarked ? "Remove bookmark" : "Bookmark")

            Menu {
                if canExtract {
                    Button { Task { await extract() } } label: { Label("Extract Text", systemImage: "text.viewfinder") }
                }
                Button(role: .destructive) {
                    store.delete(current)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
            .disabled(isExtracting)
        }
    }

    private var copyBar: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .frame(maxWidth: .infinity)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .scaleEffect(copied && !reduceMotion ? 0.985 : 1)
        .padding()
        .background(copyBarBackground)
    }

    @ViewBuilder private var copyBarBackground: some View {
        if reduceTransparency {
            Color.yankRaised
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    // MARK: - Behaviour

    private func copy() {
        Task { @MainActor in
            guard await store.copyToPasteboard(current) else { return }
            IOSMotion.successFeedback()
            UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard")
            withAnimation(IOSMotion.state(reduceMotion)) { copied = true }
            try? await Task.sleep(for: .milliseconds(1_400))
            withAnimation(IOSMotion.state(reduceMotion)) { copied = false }
        }
    }

    private func addTag() {
        let tag = TagChip.normalize(newTag)
        guard !tag.isEmpty else { return }
        store.addTag(tag, to: current)
        withAnimation(IOSMotion.state(reduceMotion)) { newTag = "" }
    }

    private func extract() async {
        // Convert on the main actor so only the Sendable CGImage crosses to the OCR task.
        guard let cgImage = model.previewImage?.cgImage else { return }
        isExtracting = true
        defer { isExtracting = false }
        if let text = await OCRService.shared.recognizeText(from: cgImage) {
            store.setOCRText(text, for: current)
            withAnimation(IOSMotion.state(reduceMotion)) { localOCR = text }
        }
    }
}

@MainActor
@Observable
final class ClipDetailContentModel {
    var previewImage: UIImage?
    var visibleText = ""
    var totalBytes = 0
    var loadedCharCount = 0
    var reachedEOF = true
    var isLoadingMore = false
    var itemSize: Int?

    private let store: ClipStore

    private static let chunkSize = 2_000
    private static let initialChars = 2_000

    private static let previewMaxPixel = 1_600

    var hasMore: Bool { !reachedEOF && loadedCharCount >= Self.initialChars }

    init(store: ClipStore) { self.store = store }

    func load(_ item: ClipboardItem) async {
        previewImage = nil
        visibleText = ""
        totalBytes = 0
        loadedCharCount = 0
        reachedEOF = true
        isLoadingMore = false
        itemSize = store.itemSize(for: item)
        switch item.type {
        case .image:
            previewImage = await loadImage(item)
        case .text:
            if item.isFileBacked {
                await loadChunk(item, charCount: Self.initialChars)
            } else {
                visibleText = item.textContent ?? ""
                reachedEOF = true
            }
        }
    }

    func loadNextChunk(_ item: ClipboardItem) async {
        guard !isLoadingMore && hasMore else { return }
        await loadChunk(item, charCount: loadedCharCount + Self.chunkSize)
    }

    private func loadChunk(_ item: ClipboardItem, charCount: Int) async {
        isLoadingMore = true
        let textURL = store.blobURL(for: item)
        let result = await Task.detached(priority: .userInitiated) {
            ClipStore.textChunk(for: item, textURL: textURL, charCount: charCount)
        }.value
        if let result {
            visibleText = result.text
            totalBytes = result.totalBytes
            loadedCharCount = result.text.count
            reachedEOF = result.reachedEOF
        }
        isLoadingMore = false
    }

    private func loadImage(_ item: ClipboardItem) async -> UIImage? {
        guard let url = store.blobURL(for: item) else { return nil }
        let cgImage = await ThumbnailCache.shared.loadThumbnail(for: item.id, at: url, maxPixel: Self.previewMaxPixel)
        return cgImage.map(UIImage.init)
    }

    func formattedBytes(_ bytes: Int) -> String {
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.bytes, .kb, .mb]))
    }
}
