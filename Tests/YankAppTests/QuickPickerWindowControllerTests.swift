import AppKit
import Foundation
import Testing
@testable import Yank

@Suite("Quick Picker Window", .serialized)
@MainActor
struct QuickPickerWindowControllerTests {
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
