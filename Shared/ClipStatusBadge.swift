import SwiftUI

/// Pin / bookmark status glyph for a clip. Pin takes precedence over bookmark; nothing
/// renders when neither applies. Pin uses the environment `.tint` (each app's AA-safe
/// foreground); bookmark uses the tuned `yankBookmark` gold; `font` matches the caller's ramp.
struct ClipStatusBadge: View {
    let item: ClipboardItem
    var font: Font = ClipStatusBadge.platformFont

    fileprivate static var platformFont: Font {
        #if os(iOS)
        .yank(.caption2)
        #else
        .system(size: TypeScale.micro)
        #endif
    }

    var body: some View {
        if item.isPinned {
            Image(systemName: "pin.fill")
                .font(font)
                .foregroundStyle(.tint)
                .accessibilityLabel("Pinned")
        } else if item.isBookmarked {
            Image(systemName: "bookmark.fill")
                .font(font)
                .foregroundStyle(Color.yankBookmark)
                .accessibilityLabel("Bookmarked")
        }
    }
}

/// Rich-content availability glyph for a clip; renders nothing for `.none`.
struct RichContentBadge: View {
    let state: ClipboardItem.RichContentState
    var font: Font = ClipStatusBadge.platformFont

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .availableLocally:
            Image(systemName: "wand.and.stars.inverse")
                .font(font)
                .foregroundStyle(Color.yankTextTertiary)
                .help(localArchiveLabel)
                .accessibilityLabel(localArchiveLabel)
        case .unavailableOnThisDevice:
            Image(systemName: "wand.and.stars")
                .font(font)
                .foregroundStyle(Color.yankTextTertiary)
                .help("Extra formatting is unavailable on this device")
                .accessibilityLabel("Extra formatting unavailable on this device")
        }
    }

    private var localArchiveLabel: String {
        #if os(macOS)
        "Formatted content preserved on this Mac"
        #else
        "Formatted content preserved on this device"
        #endif
    }
}
