import Testing
@testable import YankCore

@Suite struct AITagCleanerTests {

    @Test func lowercasesAndCaps() {
        #expect(AITagCleaner.clean(["Programming", "JavaScript", "Development"])
                == ["programming", "javascript", "development"])
    }

    @Test func capsAtLimit() {
        #expect(AITagCleaner.clean(["one", "two", "three", "four"]) == ["one", "two", "three"])
    }

    @Test func dropsShortAndDuplicates() {
        #expect(AITagCleaner.clean(["a", "ok", "ok", "OK"]) == ["ok"])
    }

    @Test func dashesWhitespaceAndStripsPunctuation() {
        #expect(AITagCleaner.clean(["Swift Code!!", "  spaced  out  "]) == ["swift-code", "spaced-out"])
    }

    @Test func dropsTagsTheUserAlreadyApplied() {
        #expect(AITagCleaner.clean(["api", "docs"], existing: ["API"]) == ["docs"])
    }

    @Test func dropsEmptyAfterNormalization() {
        #expect(AITagCleaner.clean(["!!!", "---", "ok"]) == ["ok"])
    }
}

@Suite struct AITitleCleanerTests {

    @Test func collapsesWhitespaceToOneLine() {
        #expect(AITitleCleaner.clean("  Login   handler\nfor   auth ") == "Login handler for auth")
    }

    @Test func dropsTooShort() {
        #expect(AITitleCleaner.clean("ok") == nil)
        #expect(AITitleCleaner.clean("   ") == nil)
        #expect(AITitleCleaner.clean(nil) == nil)
    }

    @Test func capsLength() {
        let long = String(repeating: "a", count: 200)
        #expect(AITitleCleaner.clean(long, limit: 80)?.count == 80)
    }
}
