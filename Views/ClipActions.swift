import SwiftUI

/// The per-clip commands the right-click menu and the hover strip share, so the two entry
/// points can never drift apart. Each closure already knows which clip(s) it acts on.
struct ClipActions {
    let paste: () -> Void
    let copy: () -> Void
    let togglePin: () -> Void
    let toggleBookmark: () -> Void
    let addTag: () -> Void
    let delete: () -> Void
}

/// Right-click (and Control-click) menu for a clip in every history layout.
struct ClipContextMenu: View {
    let item: ClipboardItem
    let actions: ClipActions

    var body: some View {
        Button("Paste", action: actions.paste)
        Button("Copy", action: actions.copy)
        Divider()
        Button(ClipActionCopy.pin(isPinned: item.isPinned), action: actions.togglePin)
        Button(ClipActionCopy.bookmark(isBookmarked: item.isBookmarked), action: actions.toggleBookmark)
        Button("Add Tag…", action: actions.addTag)
        Divider()
        Button("Delete", role: .destructive, action: actions.delete)
    }
}

/// Pin, Bookmark and Add Tag buttons shown over a hovered clip. Delete is deliberately absent:
/// a delete slides the next clip under the same pointer position, so a double-click could
/// delete two clips while only the last one stays undoable.
struct ClipHoverActions: View {
    let item: ClipboardItem
    let actions: ClipActions

    private static let buttonGap = Space.xxs

    var body: some View {
        HStack(spacing: Self.buttonGap) {
            IconButton(systemName: item.isPinned ? "pin.fill" : "pin",
                       label: ClipActionCopy.pin(isPinned: item.isPinned),
                       help: "\(ClipActionCopy.pin(isPinned: item.isPinned)) (⌘P)",
                       tint: item.isPinned ? AppTheme.active.foreground : .secondary,
                       size: TypeScale.control,
                       action: actions.togglePin)
            IconButton(systemName: item.isBookmarked ? "bookmark.fill" : "bookmark",
                       label: ClipActionCopy.bookmark(isBookmarked: item.isBookmarked),
                       help: "\(ClipActionCopy.bookmarkHelp(isBookmarked: item.isBookmarked)) (⌘B)",
                       tint: item.isBookmarked ? Color.yankBookmark : .secondary,
                       size: TypeScale.control,
                       action: actions.toggleBookmark)
            IconButton(systemName: "tag",
                       label: "Add Tag",
                       help: "Add Tag (⌘T)",
                       size: TypeScale.control,
                       action: actions.addTag)
        }
        .padding(.horizontal, Self.buttonGap)
        // Opaque so it fully covers the shortcut badge, age and sync text beneath it.
        .background(Color.yankRaised, in: RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        // The same actions are VoiceOver actions on the clip itself.
        .accessibilityHidden(true)
    }
}

private struct ClipHoverActionsModifier: ViewModifier {
    let item: ClipboardItem
    let actions: ClipActions
    let alignment: Alignment
    let isEnabled: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .overlay(alignment: alignment) {
                if isEnabled && isHovered {
                    ClipHoverActions(item: item, actions: actions)
                        .padding(Space.xs)
                }
            }
    }
}

extension View {
    /// Overlays the hover-only action strip at `alignment` while the pointer is over the view.
    func clipHoverActions(for item: ClipboardItem, actions: ClipActions,
                          alignment: Alignment, isEnabled: Bool) -> some View {
        modifier(ClipHoverActionsModifier(item: item, actions: actions, alignment: alignment, isEnabled: isEnabled))
    }
}
