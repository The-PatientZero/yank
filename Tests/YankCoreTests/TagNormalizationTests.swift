import Foundation
import Testing
@testable import YankCore

@Suite("Tag normalization")
struct TagNormalizationTests {
    @Test("A tag is lowercased and whitespace becomes a single dash")
    func lowercasesAndDashes() {
        #expect(TagNormalization.normalize("Work") == "work")
        #expect(TagNormalization.normalize("Design System") == "design-system")
        #expect(TagNormalization.normalize("read   later") == "read-later")
        #expect(TagNormalization.normalize("\tmixed \n whitespace ") == "mixed-whitespace")
    }

    @Test("Punctuation is dropped rather than kept as part of the token")
    func punctuationIsDropped() {
        #expect(TagNormalization.normalize("C++") == "c")
        #expect(TagNormalization.normalize("front/back") == "frontback")
        #expect(TagNormalization.normalize("#hash") == "hash")
        #expect(TagNormalization.normalize("a.b,c!") == "abc")
    }

    @Test("Leading and trailing dashes are trimmed")
    func dashesAreTrimmed() {
        #expect(TagNormalization.normalize("-work-") == "work")
        #expect(TagNormalization.normalize("   spaced   ") == "spaced")
        #expect(TagNormalization.normalize("---") == "")
        #expect(TagNormalization.normalize("") == "")
    }

    @Test("Letters and digits outside ASCII are kept")
    func unicodeLettersAndDigitsSurvive() {
        #expect(TagNormalization.normalize("Résumé") == "résumé")
        #expect(TagNormalization.normalize("旅行") == "旅行")
        #expect(TagNormalization.normalize("q3-2026") == "q3-2026")
    }

    @Test("A tag is capped at the shared maximum length")
    func lengthIsCapped() {
        let long = String(repeating: "a", count: TagNormalization.maximumLength + 10)

        #expect(TagNormalization.normalize(long).count == TagNormalization.maximumLength)
        #expect(TagNormalization.normalize(long) == String(repeating: "a", count: 24))
    }

    /// The reason the rule is shared: the enricher deduplicates its candidates against the
    /// user's existing tags, which is only exact if both sides were normalized identically.
    @Test("A suggested tag matching an existing tag is not offered again")
    func enricherDeduplicatesAgainstNormalizedUserTags() {
        let existing = [TagNormalization.normalize("Design System")]

        let cleaned = AITagCleaner.clean(["design system", "Design  System", "typography"],
                                         existing: existing)

        #expect(cleaned == ["typography"])
    }

    @Test("The enricher and the tag field agree on every vector")
    func producersAgree() {
        for input in ["Work", "C++", "Design System", "  spaced  ", "Résumé", "-x-"] {
            #expect(
                AITagCleaner.normalize(input) == TagNormalization.normalize(input),
                "Producers disagree on \(input)"
            )
        }
    }
}
