import Foundation
import Testing
@testable import YankCore

@Suite struct TagSuggestionsTests {
    private let tags = ["idea", "swift", "swiftui", "work"]

    @Test func nonHashQueryReturnsAllTags() {
        #expect(TagSuggestions.matching(searchText: "swi", in: tags) == tags)
        #expect(TagSuggestions.matching(searchText: "", in: tags) == tags)
    }

    @Test func bareHashReturnsAllTags() {
        #expect(TagSuggestions.matching(searchText: "#", in: tags) == tags)
    }

    @Test func hashPrefixFiltersCaseInsensitively() {
        #expect(TagSuggestions.matching(searchText: "#swi", in: tags) == ["swift", "swiftui"])
        #expect(TagSuggestions.matching(searchText: "#SWI", in: tags) == ["swift", "swiftui"])
    }

    @Test func noMatchReturnsEmpty() {
        #expect(TagSuggestions.matching(searchText: "#zzz", in: tags).isEmpty)
    }

    @Test func orderIsPreserved() {
        #expect(TagSuggestions.matching(searchText: "#", in: ["work", "idea"]) == ["work", "idea"])
    }

    @Test func completionPrefersExactMatchOverPrefix() {
        #expect(TagSuggestions.completion(searchText: "#swift", in: ["swiftui", "swift"]) == "swift")
    }

    @Test func completionUsesFirstPrefixMatchForPartialTag() {
        #expect(TagSuggestions.completion(searchText: "#swi", in: ["swift", "swiftui"]) == "swift")
    }

    @Test func completionRejectsNonTagSearch() {
        #expect(TagSuggestions.completion(searchText: "swift", in: ["swift"]) == nil)
    }
}
