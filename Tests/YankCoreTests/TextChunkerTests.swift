import Testing
import Foundation
@testable import YankCore

@Suite("TextChunker")
struct TextChunkerTests {

    @Test("bytesToRead budgets four bytes per character for ASCII")
    func bytesToReadBudgetsFourBytesPerChar() {
        #expect(TextChunker.bytesToRead(charCount: 10, totalBytes: 1_000) == 40)
    }

    @Test("bytesToRead clamps to the total byte count")
    func bytesToReadClampsToTotalBytes() {
        #expect(TextChunker.bytesToRead(charCount: 100, totalBytes: 12) == 12)
    }

    @Test("bytesToRead clamps when the file is exactly the budget")
    func bytesToReadAtExactBudget() {
        #expect(TextChunker.bytesToRead(charCount: 3, totalBytes: 12) == 12)
        #expect(TextChunker.bytesToRead(charCount: 3, totalBytes: 11) == 11)
    }

    @Test("page from data takes exactly charCount and reports the bytes used")
    func pageFromDataTruncatesWithoutEOF() {
        let data = Data("abcdefghij".utf8)
        let page = TextChunker.page(from: data, charCount: 4, windowReachesEOF: false)
        #expect(page?.text == "abcd")
        #expect(page?.consumedBytes == 4)
    }

    @Test("page from data shorter than charCount at the end of the file returns what is left")
    func pageFromDataShortDecodeReachesEOF() {
        let data = Data("abc".utf8)
        let page = TextChunker.page(from: data, charCount: 8, windowReachesEOF: true)
        #expect(page?.text == "abc")
        #expect(page?.consumedBytes == 3)
    }

    @Test("page from data that ends exactly at charCount needs more bytes unless it is the end")
    func pageFromDataExactBoundaryNeedsMoreBytes() {
        let data = Data("abcd".utf8)
        #expect(TextChunker.page(from: data, charCount: 4, windowReachesEOF: false) == nil)
        #expect(TextChunker.page(from: data, charCount: 4, windowReachesEOF: true)?.text == "abcd")
    }

    @Test("page from data counts multi-byte scalars as single characters")
    func pageFromDataCountsScalarsNotBytes() {
        let data = Data("héllo".utf8)
        let page = TextChunker.page(from: data, charCount: 3, windowReachesEOF: false)
        #expect(page?.text == "hél")
        #expect(page?.consumedBytes == 4)
    }

    @Test("page from string truncates and reports more remaining")
    func pageFromStringTruncatesWithoutEOF() {
        let page = TextChunker.page(from: "abcdefghij", charCount: 4)
        #expect(page.text == "abcd")
        #expect(page.reachedEOF == false)
    }

    @Test("page from string shorter than charCount reaches EOF")
    func pageFromStringShortReachesEOF() {
        let page = TextChunker.page(from: "abc", charCount: 8)
        #expect(page.text == "abc")
        #expect(page.reachedEOF == true)
    }

    @Test("page from string at the exact charCount boundary reaches EOF")
    func pageFromStringExactBoundaryReachesEOF() {
        let page = TextChunker.page(from: "abcd", charCount: 4)
        #expect(page.text == "abcd")
        #expect(page.reachedEOF == true)
    }
}
