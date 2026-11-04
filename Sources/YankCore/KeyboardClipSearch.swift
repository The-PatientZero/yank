import Foundation

/// Pure keyboard-extension list helper. The extension renders only text clips and works from the
/// history the host already loaded, so the memory-constrained keyboard never holds a second copy
/// of the history's text (the store already holds it once).
enum KeyboardClipSearch {
    /// Live text clips, order preserved, including preview-only ones (listed but not insertable).
    /// Used to decide whether the keyboard has anything to show and to build its filtered lists.
    static func listableItems(from items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { !$0.isDeleted && $0.textContent != nil }
    }
}
