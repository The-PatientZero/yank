import AppKit
import SwiftUI
import Testing
@testable import Yank

@Suite("Status Menu View")
@MainActor
struct StatusMenuViewTests {
    @Test("Actionable update row is keyboard focusable")
    func actionableUpdateRowIsKeyboardFocusable() throws {
        let rows = StatusMenuView.orderedRows(
            hotkeyUnavailable: false,
            updateAction: .openReleaseNotes
        )

        let quickPickerIndex = try #require(rows.firstIndex(of: .openQuickPicker))
        let fullHistoryIndex = try #require(rows.firstIndex(of: .openHistory))
        let pasteSequenceIndex = try #require(rows.firstIndex(of: .pasteSequence))
        let settingsIndex = try #require(rows.firstIndex(of: .settings))
        let updateIndex = try #require(rows.firstIndex(of: .update))
        let restartIndex = try #require(rows.firstIndex(of: .restart))

        #expect(quickPickerIndex < fullHistoryIndex)
        #expect(fullHistoryIndex < pasteSequenceIndex)
        #expect(pasteSequenceIndex < settingsIndex)
        #expect(settingsIndex < updateIndex)
        #expect(updateIndex < restartIndex)
    }

    @Test("Passive update state is not in focus order")
    func passiveUpdateStateIsNotInFocusOrder() {
        let rows = StatusMenuView.orderedRows(hotkeyUnavailable: false, updateAction: nil)

        #expect(!rows.contains(.update))
    }

    @Test("Repeat Previous joins keyboard focus order only when eligible")
    func repeatPreviousEligibilityControlsFocusOrder() throws {
        let eligible = StatusMenuView.orderedRows(
            canRepeatPasteSequence: true,
            hotkeyUnavailable: false,
            updateAction: nil
        )
        let ineligible = StatusMenuView.orderedRows(
            canRepeatPasteSequence: false,
            hotkeyUnavailable: false,
            updateAction: nil
        )

        let sequenceIndex = try #require(eligible.firstIndex(of: .pasteSequence))
        let repeatIndex = try #require(eligible.firstIndex(of: .repeatPasteSequence))
        let pauseIndex = try #require(eligible.firstIndex(of: .togglePause))
        #expect(sequenceIndex < repeatIndex)
        #expect(repeatIndex < pauseIndex)
        #expect(!ineligible.contains(.repeatPasteSequence))
    }
}

@Suite("Yank Brand")
@MainActor
struct YankBrandTests {
    @Test("Brand glyph preserves its amber color")
    func brandGlyphPreservesAmberColor() throws {
        let renderer = ImageRenderer(content: YankBrandGlyph(size: 18))
        renderer.scale = 3

        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))

        let containsAmberPixel = (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.alphaComponent > 0.5
                    && color.redComponent > 0.8
                    && color.greenComponent > 0.45
                    && color.greenComponent < 0.9
                    && color.blueComponent < 0.35
            }
        }

        #expect(containsAmberPixel)
    }
}
