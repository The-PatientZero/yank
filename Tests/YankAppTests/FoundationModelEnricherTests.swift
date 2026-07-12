import Testing
@testable import Yank

@Suite("Foundation Model Enricher")
struct FoundationModelEnricherTests {
    @Test("Requests tags without titles")
    func promptRequestsTagsOnly() {
        let prompt = FoundationModelEnricher.instructions.lowercased()

        #expect(prompt.contains("tags"))
        #expect(!prompt.contains("title"))
    }
}
