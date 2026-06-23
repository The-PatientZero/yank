import SwiftUI

/// The pin / bookmark status glyph for a clip. Pinned takes precedence over bookmarked,
/// and nothing renders when the clip is neither — so the single precedence rule, the
/// brand colours, and the VoiceOver labels live in one place, shared by the list rows,
/// the tiles, and the peek on both platforms instead of being reimplemented in each.
///
/// Pin uses the environment `.tint`, which both apps set to the theme's AA-safe
/// foreground at their history roots; bookmark uses the tuned `yankBookmark` gold.
/// `font` lets each surface match its own type ramp (fixed `TypeScale` on macOS, the
/// Dynamic-Type `.yank(_:)` styles on iOS).
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
