import Foundation
import Testing
@testable import Yank

@Suite("Yank Ink")
struct YankInkTests {
    @Test("Tag palette identity is deterministic")
    func stableTagPaletteIdentity() {
        #expect(YankInk.tagPaletteIndex(for: "work") == 2)
        #expect(YankInk.tagPaletteIndex(for: "personal") == 3)
        #expect(YankInk.tagPaletteIndex(for: "résumé") == 3)
        #expect(YankInk.tagPaletteIndex(for: "旅行") == 5)
    }

    @Test("Tag palette identity stays within the palette")
    func tagPaletteBounds() {
        for tag in ["", "Work", "inbox", String(repeating: "long-tag", count: 20)] {
            let index = YankInk.tagPaletteIndex(for: tag)
            #expect(YankInk.tagPalette.indices.contains(index))
        }
    }

    @Test("Success badge pair meets WCAG AA for small text")
    func successBadgeContrast() {
        #expect(contrast(YankInk.onSuccess.light, YankInk.successFill.light) >= 4.5)
        #expect(contrast(YankInk.onSuccess.dark, YankInk.successFill.dark) >= 4.5)
    }

    private func contrast(_ foreground: Int, _ background: Int) -> Double {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ rgb: Int) -> Double {
        let red = linearized((rgb >> 16) & 0xFF)
        let green = linearized((rgb >> 8) & 0xFF)
        let blue = linearized(rgb & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func linearized(_ channel: Int) -> Double {
        let value = Double(channel) / 255
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}
