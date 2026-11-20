import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Yank

@Suite("Quick Picker Window", .serialized)
@MainActor
struct QuickPickerWindowControllerTests {
    @Test("Panel uses the canonical frame without titlebar safe-area inflation")
    func panelUsesCanonicalFrameAndAccessibilityTitle() throws {
        let frameKey = "QuickPickerWindowFrame"
        let defaults = UserDefaults.standard
        let originalFrame = defaults.object(forKey: frameKey)
        defaults.set(
            NSStringFromRect(NSRect(x: 160, y: 240, width: 392, height: 462)),
            forKey: frameKey
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankQuickPickerFrameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let controller = QuickPickerWindowController(
            store: ClipboardStore(settings: .unbounded, storageDirectory: directory),
            axPermission: AccessibilityPermission(),
            onOpenFullHistory: {}
        )
        defer {
            controller.close()
            if let originalFrame {
                defaults.set(originalFrame, forKey: frameKey)
            } else {
                defaults.removeObject(forKey: frameKey)
            }
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove frame test directory: \(error)")
            }
        }

        let window = try #require(controller.window)
        let host = try #require(window.contentView as? NSHostingView<QuickPickerView>)

        #expect(window.frame.origin == NSPoint(x: 160, y: 240))
        #expect(window.frame.size == QuickPickerLayout.size)
        #expect(host.safeAreaRegions.isEmpty)
        #expect(window.accessibilityTitle() == "Yank Quick Picker")
    }

    @Test("Thumbnail frame clips drawing to the icon bounds")
    func thumbnailDrawingStaysInsideIconFrame() throws {
        let renderer = ImageRenderer(
            content: ZStack(alignment: .leading) {
                Color.clear.frame(width: 90, height: IconSize.clipRow)
                QuickPickerThumbnailFrame {
                    Color.red.frame(width: 90, height: IconSize.clipRow)
                }
            }
        )
        renderer.proposedSize = .init(width: 90, height: IconSize.clipRow)
        renderer.scale = 1

        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 15, y: 15)).alphaComponent > 0)
        #expect(try #require(bitmap.colorAt(x: 45, y: 15)).alphaComponent == 0)
    }

    @Test("Picker opens beside the focused field when its frame is available")
    func pickerOpensBesideFocusedFieldWhenFrameIsAvailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankQuickPickerPlacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let settings = SettingsManager.shared
        let originalPlacement = settings.quickPickerPlacement
        settings.quickPickerPlacement = .focusedInput

        let screen = try #require(NSScreen.main)
        let inputFrame = NSRect(
            x: screen.visibleFrame.minX + 120,
            y: screen.visibleFrame.maxY - 120,
            width: 320,
            height: 28
        )
        let controller = QuickPickerWindowController(
            store: ClipboardStore(settings: .unbounded, storageDirectory: directory),
            settings: settings,
            axPermission: AccessibilityPermission(),
            focusedInputFrameProvider: { _ in inputFrame },
            onOpenFullHistory: {}
        )
        defer {
            controller.close()
            settings.quickPickerPlacement = originalPlacement
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove placement test directory: \(error)")
            }
        }

        let window = try #require(controller.window)
        let expectedFrame = HistoryWindowPlacementResolver.attachedToFocusedInput(
            inputFrame: inputFrame,
            windowSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        )

        controller.showWindow(nil)

        #expect(window.frame == expectedFrame)
    }

    @Test("Search regains focus every time the picker opens")
    func searchRegainsFocusEveryTimePickerOpens() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankQuickPickerWindowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let settings = SettingsManager.shared
        let originalPlacement = settings.quickPickerPlacement
        settings.quickPickerPlacement = .center

        let controller = QuickPickerWindowController(
            store: ClipboardStore(settings: .unbounded, storageDirectory: directory),
            settings: settings,
            axPermission: AccessibilityPermission(),
            focusedInputFrameProvider: { _ in nil },
            onOpenFullHistory: {}
        )
        defer {
            controller.close()
            settings.quickPickerPlacement = originalPlacement
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove focus test directory: \(error)")
            }
        }

        let window = try #require(controller.window)
        controller.showWindow(nil)

        let focusedOnFirstOpen = try await waitForSearchFocus(in: window)
        #expect(focusedOnFirstOpen)

        controller.close()
        #expect(window.makeFirstResponder(window.contentView))
        #expect(window.firstResponder === window.contentView)

        controller.showWindow(nil)

        let focusedOnSecondOpen = try await waitForSearchFocus(in: window)
        #expect(focusedOnSecondOpen)
    }

    private func waitForSearchFocus(in window: NSWindow) async throws -> Bool {
        for _ in 0 ..< 50 {
            if window.firstResponder is NSTextView {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@Suite("Quick Picker Smart Search", .serialized)
@MainActor
struct QuickPickerSmartSearchStateTests {
    @Test("A query edit invalidates a cancellation-ignoring completion")
    func queryEditRejectsOldCompletion() async throws {
        let state = QuickPickerSmartSearchState()
        let probe = QuickPickerSmartSearchProbe()
        let oldResult = ClipboardItem.text("old")
        let newResult = ClipboardItem.text("new")

        state.interpret("old query") { phrase in
            await probe.search(phrase)
        }
        try await waitUntil { probe.pendingCount == 1 }

        state.queryDidChange()
        #expect(!state.isInterpreting)
        #expect(!state.hasOwnedTask)
        #expect(state.results == nil)

        state.interpret("new query") { phrase in
            await probe.search(phrase)
        }
        try await waitUntil { probe.pendingCount == 2 }

        probe.resume("old query", with: [oldResult])
        await settleTasks()

        #expect(state.isInterpreting)
        #expect(state.hasOwnedTask)
        #expect(state.results == nil)

        probe.resume("new query", with: [newResult])
        try await waitUntil { state.results?.map(\.id) == [newResult.id] }
        #expect(!state.isInterpreting)
        #expect(!state.hasOwnedTask)
    }

    @Test("Out-of-order completions keep the newest result")
    func outOfOrderCompletionKeepsNewestResult() async throws {
        let state = QuickPickerSmartSearchState()
        let probe = QuickPickerSmartSearchProbe()
        let firstResult = ClipboardItem.text("first")
        let secondResult = ClipboardItem.text("second")

        state.interpret("first query") { phrase in
            await probe.search(phrase)
        }
        try await waitUntil { probe.pendingCount == 1 }
        state.interpret("second query") { phrase in
            await probe.search(phrase)
        }
        try await waitUntil { probe.pendingCount == 2 }

        probe.resume("second query", with: [secondResult])
        try await waitUntil { state.results?.map(\.id) == [secondResult.id] }
        let acceptedRevision = state.resultRevision

        probe.resume("first query", with: [firstResult])
        await settleTasks()

        #expect(state.results?.map(\.id) == [secondResult.id])
        #expect(state.resultRevision == acceptedRevision)
        #expect(!state.isInterpreting)
        #expect(!state.hasOwnedTask)
    }

    @Test("Disappearance invalidates a cancellation-ignoring completion")
    func disappearanceRejectsOldCompletion() async throws {
        let state = QuickPickerSmartSearchState()
        let probe = QuickPickerSmartSearchProbe()

        state.interpret("pending query") { phrase in
            await probe.search(phrase)
        }
        try await waitUntil { probe.pendingCount == 1 }

        state.disappear()
        #expect(!state.isInterpreting)
        #expect(!state.hasOwnedTask)

        probe.resume("pending query", with: [.text("late")])
        await settleTasks()

        #expect(state.results == nil)
        #expect(state.resultRevision == 0)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            await Task.yield()
        }
        throw QuickPickerSmartSearchTestError.timedOut
    }

    private func settleTasks() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }
}

@MainActor
private final class QuickPickerSmartSearchProbe {
    private struct PendingSearch {
        let phrase: String
        let continuation: CheckedContinuation<[ClipboardItem], Never>
    }

    private var pending: [PendingSearch] = []

    var pendingCount: Int { pending.count }

    func search(_ phrase: String) async -> [ClipboardItem] {
        await withCheckedContinuation { continuation in
            pending.append(PendingSearch(phrase: phrase, continuation: continuation))
        }
    }

    func resume(_ phrase: String, with results: [ClipboardItem]) {
        guard let index = pending.firstIndex(where: { $0.phrase == phrase }) else { return }
        let search = pending.remove(at: index)
        search.continuation.resume(returning: results)
    }
}

private enum QuickPickerSmartSearchTestError: Error {
    case timedOut
}
