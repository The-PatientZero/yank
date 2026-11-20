import Testing
import YankCore

@Suite("Public legacy title API")
struct PublicLegacyTitleAPITests {
    @Test("The 1.0.x title signatures remain source-compatible")
    func legacyTitleSourceSignaturesRemainAvailable() {
        let initializer: ([String], String?) -> ClipEnrichment =
            ClipEnrichment.init(tags:title:)
        let titlePolicy: (Int) -> Bool =
            ClipEnrichmentPolicy.shouldGenerateTitle(textCount:)
        let titleCleaner: (String?, Int) -> String? =
            AITitleCleaner.clean(_:limit:)

        let enrichment = initializer(["swift"], "Legacy title")
        #expect(enrichment.title == "Legacy title")
        #expect(titlePolicy(ClipEnrichmentPolicy.titleMinLength))
        #expect(titleCleaner("  Legacy   title  ", 80) == "Legacy title")
    }
}
