import Testing
import Foundation
@testable import YankCore

@Suite struct ClipAIEnrichmentTests {

    @Test func roundTripsAIFields() throws {
        var item = ClipboardItem.text("hello")
        item.aiTags = ["swift", "auth"]
        item.aiTitle = "Login handler"
        item.aiEnrichedAt = Date(timeIntervalSince1970: 1000)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        #expect(decoded.aiTags == ["swift", "auth"])
        #expect(decoded.aiTitle == "Login handler")
        #expect(decoded.aiEnrichedAt == Date(timeIntervalSince1970: 1000))
    }

    @Test func decodesOldDataWithoutAIFields() throws {
        let data = try JSONEncoder().encode(ClipboardItem.text("hi"))
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["aiTags", "aiTitle", "aiEnrichedAt"] { dict.removeValue(forKey: key) }
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: stripped)
        #expect(decoded.aiTags.isEmpty)
        #expect(decoded.aiTitle == nil)
        #expect(decoded.aiEnrichedAt == nil)
    }

    @Test func setAIEnrichmentStampsEnrichedAtAndClock() {
        var items = [ClipboardItem.text("hi")]
        let id = items[0].id
        let now = Date(timeIntervalSince1970: 5)
        ClipboardMutations.setAIEnrichment(tags: ["a-tag"], title: "A Title", id: id, in: &items, now: now)
        #expect(items[0].aiTags == ["a-tag"])
        #expect(items[0].aiTitle == "A Title")
        #expect(items[0].aiEnrichedAt == now)
        #expect(items[0].modifiedAt == now)
    }

    @Test func aiTagsAreSearchableButLegacyTitleIsIgnored() {
        var item = ClipboardItem.text("nothing relevant here")
        item.aiTags = ["invoice"]
        item.aiTitle = "Quarterly budget summary"
        #expect(item.matches("invoice"))   // tag found in free-text search
        #expect(!item.matches("budget"))    // legacy titles are inactive metadata
        #expect(!item.isProtected)          // advisory — never blocks retention
    }

    // MARK: - ClipEnrichmentPolicy (gating)

    @Test func policyRequiresOptIn() {
        let item = ClipboardItem.text(String(repeating: "x", count: 10))
        #expect(ClipEnrichmentPolicy.shouldEnrich(item, enabled: false) == false)
        #expect(ClipEnrichmentPolicy.shouldEnrich(item, enabled: true) == true)
    }

    @Test func policySkipsShortTruncatedEnrichedAndNonText() {
        let short = ClipboardItem.text("hi")   // below minTextLength
        #expect(ClipEnrichmentPolicy.shouldEnrich(short, enabled: true) == false)

        let truncated = ClipboardItem.truncatedText(
            preview: String(repeating: "x", count: 10), originalSizeBytes: 999_999
        )
        #expect(ClipEnrichmentPolicy.shouldEnrich(truncated, enabled: true) == false)

        var alreadyEnriched = ClipboardItem.text(String(repeating: "x", count: 10))
        alreadyEnriched.aiEnrichedAt = Date(timeIntervalSince1970: 1)
        #expect(ClipEnrichmentPolicy.shouldEnrich(alreadyEnriched, enabled: true) == false)

        let image = ClipboardItem.image(filename: "a.png")
        #expect(ClipEnrichmentPolicy.shouldEnrich(image, enabled: true) == false)
    }

    @Test func policyTitleThreshold() {
        #expect(ClipEnrichmentPolicy.shouldGenerateTitle(textCount: ClipEnrichmentPolicy.titleMinLength - 1) == false)
        #expect(ClipEnrichmentPolicy.shouldGenerateTitle(textCount: ClipEnrichmentPolicy.titleMinLength) == true)
    }

}
