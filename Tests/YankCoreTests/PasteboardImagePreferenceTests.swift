import Foundation
import Testing
@testable import YankCore

@Suite struct PasteboardImagePreferenceTests {
    @Test func imageWithoutPlainTextIsSavedAsImage() {
        #expect(PasteboardAcknowledgement.prefersImage(in: ["public.png"]))
        #expect(PasteboardAcknowledgement.prefersImage(in: ["public.html", "public.jpeg"]))
    }

    @Test func plainTextWinsOverAnImage() {
        #expect(!PasteboardAcknowledgement.prefersImage(in: ["public.utf8-plain-text", "public.png"]))
        #expect(!PasteboardAcknowledgement.prefersImage(in: ["NSStringPboardType", "public.png"]))
    }

    @Test func noImageMeansNoImagePreference() {
        #expect(!PasteboardAcknowledgement.prefersImage(in: ["public.html"]))
        #expect(!PasteboardAcknowledgement.prefersImage(in: []))
        #expect(!PasteboardAcknowledgement.declaresImage(in: ["public.utf8-plain-text"]))
    }

    @Test func declaresImageIgnoresPlainText() {
        #expect(PasteboardAcknowledgement.declaresImage(in: ["public.utf8-plain-text", "public.heic"]))
    }
}
