import Foundation
import Testing
@testable import YankCore

@Suite struct PasteTemporaryFileCleanupTests {
    @Test func planRequiresSuccessfulPasteboardWrite() {
        let fileURL = URL(fileURLWithPath: "/tmp/YankPaste_failed/image-0001.png")

        let plan = PasteTemporaryFileCleanup.planAfterPasteboardWrite(
            fileURLs: [fileURL],
            writeSucceeded: false,
            delay: 60
        )

        #expect(plan == nil)
    }

    @Test func planIgnoresEmptyFileURLs() {
        let plan = PasteTemporaryFileCleanup.planAfterPasteboardWrite(
            fileURLs: [],
            writeSucceeded: true,
            delay: 60
        )

        #expect(plan == nil)
    }

    @Test func planCleansContainingDirectoriesAfterDelay() {
        let firstDirectory = URL(fileURLWithPath: "/tmp/YankPaste_first", isDirectory: true)
        let secondDirectory = URL(fileURLWithPath: "/tmp/YankPaste_second", isDirectory: true)
        let delay: TimeInterval = 600

        let plan = PasteTemporaryFileCleanup.planAfterPasteboardWrite(
            fileURLs: [
                firstDirectory.appendingPathComponent("image-0001.png"),
                firstDirectory.appendingPathComponent("image-0002.png"),
                secondDirectory.appendingPathComponent("image-0001.png")
            ],
            writeSucceeded: true,
            delay: delay
        )

        #expect(plan?.directories == [firstDirectory, secondDirectory])
        #expect(plan?.delay == delay)
    }
}
