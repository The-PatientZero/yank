import Foundation
import Testing
@testable import YankCore

@Suite struct ClipboardItemTests {
    @Test func textMatchesCaseInsensitively() {
        let item = ClipboardItem.text("Hello World")
        #expect(item.matches("hello"))
        #expect(item.matches("WORLD"))
        #expect(!(item.matches("xyz")))
    }

    @Test func fileBackedTextMatchesSearchIndex() {
        let item = ClipboardItem.largeText(
            preview: "first 500 chars",
            filename: "22222222-2222-4222-8222-222222222222.txt",
            searchIndex: ClipboardSearchIndex.make(for: "full body contains buried needle")
        )

        #expect(item.matches("buried"))
        #expect(item.matches("needle"))
        #expect(!(item.matches("missing")))
    }

    @Test func imageMatchesOCRText() {
        let item = ClipboardItem(id: UUID(), type: .image, imageFilename: "a.png", ocrText: "Invoice 2026 total")
        #expect(item.matches("invoice"))
        #expect(item.matches("2026"))
        #expect(!(item.matches("hello")))
    }

    @Test func imageWithoutOCRMatchesNothing() {
        let item = ClipboardItem(id: UUID(), type: .image, imageFilename: "b.png")
        #expect(!(item.matches("anything")))
    }

    @Test func isProtected() {
        #expect(!(ClipboardItem.text("plain").isProtected))
        #expect({ var i = ClipboardItem.text("p"); i.isPinned = true; return i }().isProtected)
        #expect({ var i = ClipboardItem.text("b"); i.isBookmarked = true; return i }().isProtected)
        #expect({ var i = ClipboardItem.text("t"); i.tags = ["work"]; return i }().isProtected)
    }

    @Test func relativeAge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func aged(_ seconds: Double) -> ClipboardItem {
            ClipboardItem(type: .text, timestamp: now.addingTimeInterval(-seconds), textContent: "x")
        }
        #expect(aged(30).age(asOf: now) == "now")
        #expect(aged(120).age(asOf: now) == "2m")
        #expect(aged(7_200).age(asOf: now) == "2h")
        #expect(aged(2 * 86_400).age(asOf: now) == "2d")
        #expect(aged(3 * 604_800).age(asOf: now) == "3w")
    }

    @Test func accessibilityDescriptionIncludesPresentationAndAge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let item = ClipboardItem(type: .text, timestamp: now.addingTimeInterval(-7_200), textContent: "ignored")

        #expect(
            item.accessibilityDescription(kindLabel: "note", excerpt: "Dinner notes", asOf: now) ==
            "note, Dinner notes, 2h"
        )
    }

    @Test func accessibilityDescriptionIncludesProtectionAndTags() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let item = ClipboardItem(
            type: .text,
            timestamp: now.addingTimeInterval(-120),
            textContent: "ignored",
            isPinned: true,
            isBookmarked: true,
            tags: ["work", "urgent"]
        )

        #expect(
            item.accessibilityDescription(kindLabel: "link", excerpt: "https://example.com", asOf: now) ==
            "link, https://example.com, pinned, tags: work, urgent, 2m"
        )
    }

    @Test func accessibilityDescriptionIncludesBookmarkWhenNotPinned() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let item = ClipboardItem(
            type: .text,
            timestamp: now.addingTimeInterval(-30),
            textContent: "ignored",
            isBookmarked: true
        )

        #expect(
            item.accessibilityDescription(kindLabel: "email", excerpt: "me@example.com", asOf: now) ==
            "email, me@example.com, bookmarked, now"
        )
    }

    @Test func imageAccessibilityLabelPrefersBoundedNormalizedOCR() {
        let item = ClipboardItem(
            type: .image,
            sourceApp: "Preview",
            imageFilename: "image.png",
            ocrText: String(repeating: "invoice \n", count: 30)
        )

        #expect(item.imageAccessibilityLabel.count == 160)
        #expect(item.imageAccessibilityLabel.hasPrefix("invoice invoice"))
        #expect(item.imageAccessibilityLabel.hasSuffix("…"))
        #expect(!item.imageAccessibilityLabel.contains("\n"))
    }

    @Test func imageAccessibilityLabelFallsBackToSourceThenGenericCopy() {
        let sourced = ClipboardItem(
            type: .image,
            sourceApp: "  Photos  ",
            imageFilename: "image.png",
            ocrText: " \n "
        )
        let generic = ClipboardItem(type: .image, imageFilename: "opaque-storage-name.png")

        #expect(sourced.imageAccessibilityLabel == "Photos")
        #expect(generic.imageAccessibilityLabel == "Image clip")
    }

    @Test func hasRichContentDefaultsFalse() {
        let item = ClipboardItem.text("plain")
        #expect(item.hasRichContent == false)
    }

    @Test func hasRichContentRoundTripsViaCodable() throws {
        let original = ClipboardItem(type: .text, textContent: "rich", hasRichContent: true)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ClipboardItem.self, from: data)
        #expect(restored.hasRichContent == true)
    }

    @Test func searchIndexRoundTripsViaCodable() throws {
        let original = ClipboardItem.largeText(
            preview: "preview",
            filename: "22222222-2222-4222-8222-222222222222.txt",
            searchIndex: ClipboardSearchIndex.make(for: "full body")
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ClipboardItem.self, from: data)

        #expect(restored.searchIndex == original.searchIndex)
    }

    @Test func hasRichContentDefaultsFalseForOldArchives() throws {
        let withoutField = ClipboardItem(type: .text, textContent: "old", hasRichContent: false)
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(withoutField)) as! [String: Any]
        json.removeValue(forKey: "hasRichContent")
        let stripped = try JSONDecoder().decode(
            ClipboardItem.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(stripped.hasRichContent == false)
    }

    @Test func richContentStateReflectsLocalArchiveAvailability() {
        let local = ClipboardItem(type: .text, textContent: "rich", richFilename: "archive.plist", hasRichContent: true)
        let remotePlain = ClipboardItem(type: .text, textContent: "rich", hasRichContent: true)
        let legacyLocal = ClipboardItem(type: .text, textContent: "rich", richFilename: "archive.plist")
        let plain = ClipboardItem.text("plain")

        #expect(local.richContentState == .availableLocally)
        #expect(remotePlain.richContentState == .unavailableOnThisDevice)
        #expect(legacyLocal.richContentState == .availableLocally)
        #expect(plain.richContentState == .none)
    }

    @Test func dayGroupLabel() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        func at(_ offsetDays: Int) -> ClipboardItem {
            ClipboardItem(type: .text, timestamp: cal.date(byAdding: .day, value: offsetDays, to: now)!, textContent: "x")
        }
        #expect(at(0).dayGroupLabel(asOf: now, calendar: cal) == "Today")
        #expect(at(-1).dayGroupLabel(asOf: now, calendar: cal) == "Yesterday")
        #expect(at(-5).dayGroupLabel(asOf: now, calendar: cal) != "Today")
        #expect(at(-5).dayGroupLabel(asOf: now, calendar: cal) != "Yesterday")

        // Older dates use `Date.FormatStyle` (.abbreviated), matching the production path and
        // avoiding per-call `DateFormatter` allocation. Locale-independent: both sides resolve
        // against the same current locale.
        let older = cal.date(byAdding: .day, value: -5, to: now)!
        #expect(at(-5).dayGroupLabel(asOf: now, calendar: cal) ==
                       older.formatted(date: .abbreviated, time: .omitted))
    }
}
