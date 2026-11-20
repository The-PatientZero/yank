import Foundation
import Testing
@testable import YankCore

@Suite
struct ClipboardContentFingerprintTests {
    @Test func largeTextsWithSamePrefixAndDifferentSuffixDoNotCollide() {
        let sharedPrefix = String(repeating: "A", count: 10_000)
        let first = sharedPrefix + String(repeating: "B", count: 50_000)
        let second = sharedPrefix + String(repeating: "C", count: 50_000)

        #expect(ClipboardContentFingerprint.text(first) != ClipboardContentFingerprint.text(second))
    }

    @Test func identicalLargeTextHasStableFingerprint() {
        let text = String(repeating: "stable", count: 20_000)

        #expect(ClipboardContentFingerprint.text(text) == ClipboardContentFingerprint.text(text))
    }

    @Test func kindSeparatesIdenticalBytesFromDifferentCapturePaths() {
        let bytes = Data("same bytes".utf8)

        #expect(ClipboardContentFingerprint.text("same bytes") != ClipboardContentFingerprint.image(bytes))
    }
}
