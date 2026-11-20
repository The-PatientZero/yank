import Foundation
import Testing
@testable import YankCore

@Suite struct TerminalTextCleanerTests {
    private func clean(_ text: String) -> String { TerminalTextCleaner.clean(text) }

    @Test func normalizesLineEndings() {
        #expect(clean("a\r\nb\rc") == "a\nb\nc")
    }

    @Test func removesEscapeSequences() {
        #expect(clean("\u{1B}[1;32mOK\u{1B}[0m done") == "OK done")
        #expect(clean("\u{1B}]0;title\u{07}text") == "text")
        #expect(clean("\u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
        #expect(clean("\u{1B}Mtext") == "text")
    }

    @Test func anUnterminatedOperatingSystemCommandDropsOnlyItsIntroducer() {
        #expect(clean("\u{1B}]0;title") == "0;title")
    }

    @Test func replacesNonBreakingSpacesAndDropsInvisibleCharacters() {
        #expect(clean("a\u{00A0}b\u{200B}c\u{FEFF}") == "a bc")
    }

    @Test func dropsLinesMadeOnlyOfBoxDrawing() {
        #expect(clean("╭────╮\ntext\n╰────╯") == "text")
    }

    @Test func removesFramesOnEveryLine() {
        #expect(clean("│ > hello │\n│   world │") == "> hello\n  world")
    }

    @Test func keepsAFrameCharacterThatOnlySomeLinesStartWith() {
        #expect(clean("│ one\ntwo") == "│ one\ntwo")
    }

    @Test func replacesStatusMarkersSoContinuationLinesStayAligned() {
        let input = "⏺ The build passed.        \n  Next I open the pull request.   \n"
        #expect(clean(input) == "The build passed.\nNext I open the pull request.")
        #expect(clean("  ⎿  Found 2 files\n     A.swift") == "Found 2 files\nA.swift")
    }

    @Test func stripsConsecutiveLineNumberGutters() {
        #expect(clean("     1→import Foundation\n     2→\n     3→let x = 1") == "import Foundation\n\nlet x = 1")
        #expect(clean("9\tnine\n10\tten") == "nine\nten")
    }

    @Test func keepsNumbersThatAreNotAGutter() {
        #expect(clean("12: foo\n13: bar") == "12: foo\n13: bar")
        #expect(clean("1→a\n3→b") == "1→a\n3→b")
        #expect(clean("1→only") == "1→only")
        #expect(clean("1→a\nplain") == "1→a\nplain")
    }

    @Test func trimsTrailingWhitespace() {
        #expect(clean("a   \nb\t") == "a\nb")
    }

    @Test func removesSharedIndentationButKeepsRelativeIndentation() {
        #expect(clean("    func a() {\n        return 1\n    }") == "func a() {\n    return 1\n}")
    }

    @Test func removesLeadingAndTrailingBlankLines() {
        #expect(clean("\n\n  text\n\n") == "text")
    }

    @Test func leavesOrdinaryTextAlone() {
        let prose = "Hello there.\n\nNo changes here."
        #expect(clean(prose) == prose)
        let bullets = "● first\n• second\n+ added\n- removed"
        #expect(clean(bullets) == bullets)
        #expect(clean("→ arrows stay") == "→ arrows stay")
    }

    @Test func emptyAndWhitespaceOnlyInputBecomesEmpty() {
        #expect(clean("") == "")
        #expect(clean("   \n\t\n") == "")
    }

    @Test func cleansACombinedTerminalCopy() {
        let input = "\u{1B}[2m╭──────╮\u{1B}[0m\n│ ⏺ Done.     │\n│   Next.     │\n╰──────╯"
        #expect(clean(input) == "Done.\nNext.")
    }
}
