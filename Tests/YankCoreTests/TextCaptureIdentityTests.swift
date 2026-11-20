import Foundation
import Testing
@testable import YankCore

@Suite("Text Capture Identity")
struct TextCaptureIdentityTests {
    @Test("Matches byte-identical complete plain inline text")
    func matchesExactInlineText() {
        let first = ClipboardItem.text("same text")
        let second = ClipboardItem.text("same text")

        #expect(TextCaptureIdentity.matches(first, second))
    }

    @Test("Does not normalize Unicode before comparison")
    func distinguishesCanonicalUnicodeRepresentations() {
        let composed = ClipboardItem.text("\u{00E9}")
        let decomposed = ClipboardItem.text("e\u{0301}")

        #expect(!TextCaptureIdentity.matches(composed, decomposed))
    }

    @Test("Keeps case and whitespace differences distinct")
    func distinguishesCaseAndWhitespace() {
        let baseline = ClipboardItem.text("Value")

        #expect(!TextCaptureIdentity.matches(baseline, .text("value")))
        #expect(!TextCaptureIdentity.matches(baseline, .text("Value ")))
        #expect(!TextCaptureIdentity.matches(baseline, .text("Value\n")))
    }

    @Test("Rejects file-backed and truncated text")
    func rejectsIncompleteInlinePayloads() {
        let inline = ClipboardItem.text("preview")
        let fileBacked = ClipboardItem.largeText(preview: "preview", filename: "full.txt")
        let truncated = ClipboardItem.truncatedText(preview: "preview", originalSizeBytes: 1_000)

        #expect(!TextCaptureIdentity.matches(inline, fileBacked))
        #expect(!TextCaptureIdentity.matches(inline, truncated))
    }

    @Test("Rejects rich text even when its plain text is identical")
    func rejectsRichText() {
        let plain = ClipboardItem.text("formatted")
        var rich = ClipboardItem.text("formatted")
        rich.hasRichContent = true

        #expect(!TextCaptureIdentity.matches(plain, rich))
    }

    @Test("Rejects a local rich archive even when the legacy marker is absent")
    func rejectsLocalRichArchive() {
        let plain = ClipboardItem.text("formatted")
        let rich = ClipboardItem(type: .text, textContent: "formatted", richFilename: "archive.plist")

        #expect(!TextCaptureIdentity.matches(plain, rich))
    }

    @Test("Rejects non-text items")
    func rejectsImages() {
        let text = ClipboardItem.text("same")
        let image = ClipboardItem(type: .image, textContent: "same", imageFilename: "image.png")

        #expect(!TextCaptureIdentity.matches(text, image))
    }
}
