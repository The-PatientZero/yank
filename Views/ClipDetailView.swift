import AppKit
import SwiftUI

/// Renders the focused clip (or the multi-selection summary) — the "peek" content.
/// Pure renderer: all transient state and loading live in `ClipDetailModel`.
struct ClipDetailView: View {
    let store: ClipboardStore
    let selectedItems: [ClipboardItem]
    @Bindable var model: ClipDetailModel
    let onCopy: (ClipboardItem) -> Void
    let onDownloadImages: () -> Void
    let onDelete: (ClipboardItem) -> Void

    @FocusState private var isTagInputFocused: Bool

    private var primary: ClipboardItem? { selectedItems.first }
    private var count: Int { selectedItems.count }
    private var totalSize: Int {
        selectedItems.reduce(0) { $0 + (store.itemSize(for: $1) ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                if count > 1 {
                    multiSelectionSummary
                        .padding(Space.xl)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else if let item = primary {
                    itemContent(item)
                        .padding(Space.xl)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    emptyState
                }
            }

            if count <= 1, let item = primary {
                Divider()
                tagSection(for: item)
            }
        }
        .onChange(of: model.showTagInput) { _, newValue in
            if newValue {
                Task { @MainActor in isTagInputFocused = true }
            } else {
                isTagInputFocused = false
            }
        }
    }

    /// No selection — an SF Symbol over one warm line, mirroring the exclusions empty
    /// state so the app's empty surfaces speak in one voice.
    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: TypeScale.display, weight: .light))
                .foregroundColor(.yankTextTertiary)
                .accessibilityHidden(true)
            Text("Pick a clip to peek inside.")
                .font(.system(size: TypeScale.body, design: .serif))
                .italic()
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No clip selected")
        .accessibilityHint("Pick a clip from the list to preview it here.")
    }

    /// While the thumbnail decodes off-thread, hold the eventual frame with a redacted
    /// placeholder rect instead of a naked spinner — no layout jump when the image lands.
    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Color.yankSubtleFill)
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: TypeScale.stat, weight: .light))
                    .foregroundColor(.yankTextTertiary)
                    .accessibilityHidden(true)
            )
            .redacted(reason: .placeholder)
            .accessibilityLabel("Loading image preview")
    }

    private var header: some View {
        HStack {
            Spacer()

            if count > 1 {
                HStack(spacing: Space.sm) {
                    Image(systemName: "checkmark.circle")
                    Text("\(count) items selected")
                }
                .font(.system(size: TypeScale.caption, weight: .medium))
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(Color.yankMultiSelect)
                .cornerRadius(Radius.sm)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(count) items selected")
            } else if let item = primary {
                HStack(spacing: Space.sm) {
                    Text(item.type == .text ? "Text" : "Image")

                    if item.isFileBacked {
                        Text("Large")
                            .font(.system(size: TypeScale.micro, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, Space.xs)
                            .padding(.vertical, Space.xxs)
                            // Full-strength ink: white-on-#B45309 clears AA (5.02:1).
                            .background(Color.yankOversize)
                            .cornerRadius(Radius.sm)
                    }

                    Text(model.itemSize.map { model.formattedBytes($0) } ?? "—")
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                }
                .font(.system(size: TypeScale.caption, weight: .medium))
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(AppTheme.active.selectionFill)
                .cornerRadius(Radius.sm)
            }

            Spacer()

            if count <= 1 {
                HStack(spacing: Space.lg) {
                    IconButton(systemName: "doc.on.doc", label: "Copy", help: "Copy (⌘C)") {
                        if let item = primary { onCopy(item) }
                    }

                    if primary?.type == .image && model.previewImage != nil {
                        IconButton(systemName: "arrow.down.to.line", label: "Save image", help: "Save image (⌘S)") {
                            if let item = primary { model.saveImageToDisk(item) }
                        }
                    }

                    if primary?.type == .image && model.previewImage != nil && primary?.ocrText == nil {
                        IconButton(systemName: model.isExtractingText ? "ellipsis.circle" : "text.viewfinder",
                                   label: "Extract text from image", help: "Extract Text from Image") {
                            if let item = primary { Task { await model.extractText(from: item) } }
                        }
                        .disabled(model.isExtractingText)
                    }

                    IconButton(systemName: primary?.isPinned == true ? "pin.fill" : "pin",
                               label: primary?.isPinned == true ? "Unpin" : "Pin to top",
                               help: primary?.isPinned == true ? "Unpin (⌘P)" : "Pin to top (⌘P)",
                               tint: primary?.isPinned == true ? AppTheme.active.foreground : .secondary) {
                        if let item = primary { store.togglePin(for: item) }
                    }

                    IconButton(systemName: primary?.isBookmarked == true ? "bookmark.fill" : "bookmark",
                               label: primary?.isBookmarked == true ? "Remove bookmark" : "Bookmark",
                               help: primary?.isBookmarked == true ? "Remove bookmark (⌘B)" : "Bookmark — protect from deletion (⌘B)",
                               tint: primary?.isBookmarked == true ? Color.yankBookmark : .secondary) {
                        if let item = primary { store.toggleBookmark(for: item) }
                    }

                    IconButton(systemName: "trash", label: "Delete", help: "Delete (⌘⌫)") {
                        if let item = primary { onDelete(item) }
                    }
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Color.yankRaised.opacity(0.3))
    }

    @ViewBuilder
    private var multiSelectionSummary: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.xxl) {
                StatLabel(caption: "Items", value: "\(count)")
                StatLabel(caption: "Total Size", value: model.formattedBytes(totalSize))
                Spacer()
            }

            Divider()

            let textCount = selectedItems.filter { $0.type == .text }.count
            let imageCount = selectedItems.filter { $0.type == .image }.count

            VStack(alignment: .leading, spacing: Space.md) {
                if textCount > 0 {
                    TypeCountRow(icon: "doc.text", text: "\(textCount) text \(textCount == 1 ? "item" : "items")")
                }
                if imageCount > 0 {
                    TypeCountRow(icon: "photo", text: "\(imageCount) image \(imageCount == 1 ? "item" : "items")")
                }
            }

            Divider()

            if textCount == 0 && imageCount > 0 {
                Button(action: onDownloadImages) {
                    HStack(spacing: Space.md) {
                        Image(systemName: "arrow.down.to.line")
                        Text("Download All (\(imageCount))")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Saves all selected images to a folder you choose")

                Divider()
            }

            if let firstItem = selectedItems.first, firstItem.type == .text {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("First item preview")
                        .font(.system(size: TypeScale.caption, weight: .medium))
                        .foregroundColor(.yankTextTertiary)

                    let preview = (firstItem.textContent ?? "").prefix(200)
                    Text(String(preview))
                        .font(.system(size: TypeScale.control))
                        .foregroundColor(.yankCodeText)
                        .lineLimit(4)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder
    private func itemContent(_ item: ClipboardItem) -> some View {
        switch item.type {
        case .text:
            if item.isTruncated {
                VStack(alignment: .leading, spacing: Space.lg) {
                    richContentNote(for: item)
                    Text(item.textContent ?? "")
                        .font(.system(size: TypeScale.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    Label("Content was too large to store (\(model.formattedBytes(item.originalSizeBytes ?? 0))). Showing first 500 characters.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: TypeScale.caption))
                        .foregroundColor(.secondary)
                        .padding(.top, Space.xs)
                }
            } else if item.isFileBacked {
                VStack(alignment: .leading, spacing: Space.lg) {
                    richContentNote(for: item)
                    textContent(item)
                }
            } else {
                VStack(alignment: .leading, spacing: Space.lg) {
                    richContentNote(for: item)
                    Text(item.textContent ?? "")
                        .font(.system(size: TypeScale.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        case .image:
            VStack(spacing: Space.lg) {
                richContentNote(for: item)
                if let img = model.previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(item.imageAccessibilityLabel)
                } else {
                    imagePlaceholder
                }

                if model.isExtractingText {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, Space.lg)
                        .accessibilityLabel("Extracting text from image")
                } else if let ocrText = item.ocrText {
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .fill(Color.yankSubtleFill)
                            .frame(height: Hairline.width)

                        HStack(alignment: .top) {
                            Text(ocrText)
                                .font(.system(size: TypeScale.body))
                                .textSelection(.enabled)
                                .lineSpacing(Space.xs)
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                            IconButton(systemName: "doc.on.doc", label: "Copy extracted text",
                                       tint: .yankTextTertiary, size: TypeScale.control) {
                                model.copyExtractedText(ocrText)
                            }
                        }
                        .padding(.top, Space.lg)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func richContentNote(for item: ClipboardItem) -> some View {
        switch item.richContentState {
        case .none:
            EmptyView()
        case .availableLocally:
            Label("Formatting is preserved when pasted from this Mac.", systemImage: "wand.and.stars.inverse")
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.secondary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(Color.yankRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.sm))
                .accessibilityElement(children: .combine)
        case .unavailableOnThisDevice:
            Label(
                "This clip included formatting when captured. Plain content is available here.",
                systemImage: "wand.and.stars"
            )
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.secondary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(Color.yankRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.sm))
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func textContent(_ item: ClipboardItem) -> some View {
        LazyVStack(spacing: Space.md, pinnedViews: []) {
            Text(model.chunkedText.visibleText)
                .font(.system(size: TypeScale.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            if model.chunkedText.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, Space.md)
                    .accessibilityLabel("Loading more text")
            } else if model.chunkedText.hasMore {
                Text("— \(model.formattedBytes(model.chunkedText.totalBytes)) total · scroll to load more —")
                    .font(.system(size: TypeScale.caption))
                    .foregroundColor(.yankTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.sm)
                    .onAppear {
                        Task { await model.loadNextChunk(item) }
                    }
            }
        }
    }

    @ViewBuilder
    private func tagSection(for item: ClipboardItem) -> some View {
        let inputSuggestions = model.showTagInput ? model.suggestions(for: item) : []
        VStack(alignment: .leading, spacing: Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(item.tags, id: \.self) { tag in
                        TagChip(label: tag, onRemove: {
                            store.removeTag(tag, from: item)
                        })
                    }
                    if model.showTagInput {
                        HStack(spacing: Space.sm) {
                            TextField("tag name", text: $model.tagInputText)
                                .textFieldStyle(.plain)
                                .font(.system(size: TypeScale.caption))
                                .focused($isTagInputFocused)
                                .frame(minWidth: 60)
                                .onSubmit { model.commitTag(to: item) }
                            Button("Cancel") { model.cancelTagInput() }
                                .buttonStyle(.plain)
                                .font(.system(size: TypeScale.caption))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: { model.beginAddTag() }) {
                            HStack(spacing: Space.sm) {
                                Image(systemName: "plus")
                                    .font(.system(size: TypeScale.micro, weight: .bold))
                                Text("Add tag")
                                    .font(.system(size: TypeScale.caption))
                                Text("⌘T")
                                    .font(.system(size: TypeScale.micro))
                                    .foregroundColor(.yankTextTertiary)
                            }
                            .foregroundColor(.yankTextTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !inputSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(inputSuggestions, id: \.self) { suggestion in
                            TagChip(label: suggestion, onTap: {
                                store.addTag(suggestion, to: item)
                                model.cancelTagInput()
                            })
                        }
                    }
                }
            }

            if model.showTagInput {
                if inputSuggestions.isEmpty && !model.tagInputText.isEmpty {
                    // Query typed but nothing matches — say so quietly; ↵ still creates it.
                    Text("No matching tags — ↵ creates “\(TagChip.normalize(model.tagInputText))”.")
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                } else {
                    // The two keys that drive the input, spelled out while it's showing.
                    Text("↵ add · ⇥ complete")
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Color.yankRaised)
    }
}

private struct StatLabel: View {
    let caption: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(caption)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundColor(.yankTextTertiary)
            Text(value)
                .font(.system(size: TypeScale.stat, weight: .semibold, design: .serif))
                .foregroundColor(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(value)")
    }
}

private struct TypeCountRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: TypeScale.control))
        }
    }
}
