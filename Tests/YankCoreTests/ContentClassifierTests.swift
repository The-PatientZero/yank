import Testing
import Foundation
@testable import YankCore

@Suite struct ContentClassifierTests {

    // MARK: Links

    @Test func detectsHTTPSLink() {
        #expect(ContentClassifier.linkURL("https://example.com/path") != nil)
        #expect(ContentClassifier.linkURL("http://example.com") != nil)
    }

    @Test func rejectsNonHTTPOrMalformedLinks() {
        #expect(ContentClassifier.linkURL("ftp://example.com") == nil)
        #expect(ContentClassifier.linkURL("not a url") == nil)
        #expect(ContentClassifier.linkURL("https://") == nil)          // no host
        #expect(ContentClassifier.linkURL("hello https://x.com") == nil) // embedded whitespace
    }

    // MARK: Email

    @Test func detectsEmail() {
        #expect(ContentClassifier.email("a@b.com") == "a@b.com")
    }

    @Test func rejectsMalformedEmail() {
        #expect(ContentClassifier.email("a@b") == nil)        // no dotted domain
        #expect(ContentClassifier.email("@b.com") == nil)     // empty local part
        #expect(ContentClassifier.email("a@@b.com") == nil)   // two @
        #expect(ContentClassifier.email("a@b.com.") == nil)   // trailing dot
        #expect(ContentClassifier.email("a b@c.com") == nil)  // whitespace
    }

    // MARK: Phone

    @Test func detectsPhone() {
        #expect(ContentClassifier.phone("+1 (555) 123-4567") == "+1 (555) 123-4567")
    }

    @Test func rejectsNonPhone() {
        #expect(ContentClassifier.phone("12345") == nil)            // < 7 digits
        #expect(ContentClassifier.phone("call 5551234567") == nil)  // letters
    }

    // MARK: Code

    @Test func detectsCodeSignals() {
        #expect(ContentClassifier.looksLikeCode("func foo() {}"))
        #expect(ContentClassifier.looksLikeCode("{ \"a\": 1 }"))
        #expect(ContentClassifier.looksLikeCode("import Foundation\n  let x = 1\n  return x"))
    }

    @Test func plainProseIsNotCode() {
        #expect(!ContentClassifier.looksLikeCode("Just a normal sentence."))
    }

    // MARK: CSS colour

    @Test func parsesHexColors() {
        #expect(ContentClassifier.cssColor("#fff")?.rgba == RGBA(red: 1, green: 1, blue: 1, opacity: 1))
        #expect(ContentClassifier.cssColor("#FF0000")?.rgba == RGBA(red: 1, green: 0, blue: 0, opacity: 1))
        let withAlpha = ContentClassifier.cssColor("#00000080")?.rgba
        #expect(withAlpha?.red == 0)
        #expect(abs((withAlpha?.opacity ?? 0) - 128.0 / 255) < 0.0001)
    }

    @Test func parsesRGBAndHSL() {
        #expect(ContentClassifier.cssColor("rgb(255, 0, 0)")?.rgba == RGBA(red: 1, green: 0, blue: 0, opacity: 1))
        let rgba = ContentClassifier.cssColor("rgba(0, 255, 0, 0.5)")?.rgba
        #expect(rgba?.green == 1)
        #expect(rgba?.opacity == 0.5)
        // hsl(0, 100%, 50%) is pure red
        let hsl = ContentClassifier.cssColor("hsl(0, 100%, 50%)")?.rgba
        #expect((hsl?.red ?? 0) > 0.99)
        #expect((hsl?.blue ?? 1) < 0.01)
    }

    @Test func rejectsNonColors() {
        #expect(ContentClassifier.cssColor("#xyz") == nil)
        #expect(ContentClassifier.cssColor("hello") == nil)
        #expect(ContentClassifier.cssColor("#12") == nil)   // invalid hex length
        #expect(ContentClassifier.cssColor("") == nil)
    }

    @Test func preservesTrimmedRawForDisplay() {
        #expect(ContentClassifier.cssColor("  #FFF  ")?.raw == "#FFF")
    }
}
