import AppKit
import Foundation
import Testing
@testable import Yank

/// Regression coverage for consecutive-duplicate suppression (removed in 1.0.4, restored).
/// Some apps re-assert pasteboard ownership with byte-identical content on activation or
/// lazy-promise re-declares; those bumps must not create duplicate history rows — including
/// rich captures, which durable-history dedup (`TextCaptureIdentity`) never collapses.
@Suite("Clipboard Watcher Consecutive Duplicate Suppression")
@MainActor
struct ClipboardWatcherFingerprintTests {
    private static let richHTML = "<b>rich</b>"

    private func writeRichText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(Self.richHTML.utf8), forType: .html)
        pasteboard.writeObjects([item])
    }

    private func capture(_ text: String, watcher: ClipboardWatcher, pasteboard: NSPasteboard) async {
        writeRichText(text, to: pasteboard)
        watcher.checkClipboard()
        await watcher.waitForCaptureQueueIdle()
    }

    @Test("A pasteboard re-assert with identical rich content does not add a second row")
    func identicalConsecutiveRichCaptureIsSuppressed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankWatcherFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.thepatientzero.yank.tests.fingerprint.\(UUID().uuidString)")
        )
        let watcher = ClipboardWatcher(
            store: store,
            settings: .unbounded,
            pasteboardName: pasteboard.name
        )

        await capture("5R8WAVC936", watcher: watcher, pasteboard: pasteboard)
        #expect(store.items.count == 1)

        // Same content, new pasteboard generation — the phantom-copy shape.
        await capture("5R8WAVC936", watcher: watcher, pasteboard: pasteboard)
        #expect(store.items.count == 1)

        await capture("something else", watcher: watcher, pasteboard: pasteboard)
        #expect(store.items.count == 2)

        // Re-copying earlier content after an intervening copy is a genuine user action.
        await capture("5R8WAVC936", watcher: watcher, pasteboard: pasteboard)
        #expect(store.items.count == 3)
    }
}
