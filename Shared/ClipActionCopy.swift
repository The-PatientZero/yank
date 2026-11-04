import Foundation

/// The wording of clip actions that both apps show, so one action reads the same on every
/// surface (buttons, menus, swipe actions, the multi-select bar, VoiceOver actions). Icons and
/// shortcut suffixes stay with each platform.
enum ClipActionCopy {
    static func pin(isPinned: Bool) -> String {
        isPinned ? "Unpin" : "Pin to top"
    }

    static func bookmark(isBookmarked: Bool) -> String {
        isBookmarked ? "Remove Bookmark" : "Bookmark"
    }

    /// Tooltip text for the bookmark button, before any shortcut suffix.
    static func bookmarkHelp(isBookmarked: Bool) -> String {
        isBookmarked ? bookmark(isBookmarked: true) : "Bookmark — protect from deletion"
    }

    /// The note under text that was too large to store in full. The number of characters shown
    /// is the stored preview length, so the sentence follows the constant that cuts the preview.
    static func tooLargeNote(sizeText: String) -> String {
        "Content was too large to store (\(sizeText)). Showing the first \(TextCapturePlan.previewLength) characters."
    }
}
