import AppKit
import Testing
@testable import Yank

@Suite("Menu bar icon style")
@MainActor
struct MenuBarIconStyleTests {
    @Test func savedStyleDefaultsToColor() {
        #expect(MenuBarIconStyle.initialStyle(storedRawValue: nil) == .color)
        #expect(MenuBarIconStyle.initialStyle(storedRawValue: "bogus") == .color)
        #expect(MenuBarIconStyle.initialStyle(storedRawValue: "plain") == .plain)
    }

    @Test func savedValuesStayStable() {
        #expect(MenuBarIconStyle.color.rawValue == "color")
        #expect(MenuBarIconStyle.plain.rawValue == "plain")
    }

    @Test func plainIconWithoutMarksIsASystemTemplate() {
        let image = HubController.glyph(for: state(.plain))

        #expect(image.isTemplate)
        #expect(image.accessibilityDescription == "Yank")
    }

    @Test func plainIconWithAMarkKeepsTheMarkColor() {
        let synced = HubController.glyph(for: state(.plain, syncProblem: true))
        let paused = HubController.glyph(for: state(.plain, paused: true))
        let update = HubController.glyph(for: state(.plain, updateText: "Update available"))

        #expect(!synced.isTemplate)
        #expect(!paused.isTemplate)
        #expect(!update.isTemplate)
        #expect(synced.accessibilityDescription == "Yank, sync problem")
    }

    @Test func colorIconIsNeverATemplate() {
        #expect(!HubController.glyph(for: state(.color)).isTemplate)
        #expect(!HubController.glyph(for: state(.color, paused: true)).isTemplate)
    }

    @Test func bothStylesDrawAVisibleIcon() throws {
        for style in MenuBarIconStyle.allCases {
            let image = HubController.glyph(for: state(style))
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
            NSGraphicsContext.restoreGraphicsState()
            let opaquePixels = (0..<36).flatMap { x in (0..<36).map { y in (x, y) } }
                .filter { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.5 }
            #expect(opaquePixels.count > 100, "The \(style) icon drew almost nothing")
        }
    }

    private func state(
        _ style: MenuBarIconStyle,
        paused: Bool = false,
        updateText: String? = nil,
        syncProblem: Bool = false
    ) -> HubController.IconState {
        HubController.IconState(style: style, paused: paused, updateText: updateText, syncProblem: syncProblem)
    }
}
