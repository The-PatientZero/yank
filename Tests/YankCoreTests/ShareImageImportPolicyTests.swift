import Foundation
import Testing
@testable import YankCore

@Suite struct ShareImageImportPolicyTests {
    @Test func inMemoryBudgetMatchesImageBlobBudget() {
        #expect(ShareImageImportPolicy.maxInMemoryImageBytes == SyncBlobKind.image.maximumBytes)
    }

    @Test func acceptsPayloadsWithinBudget() {
        #expect(ShareImageImportPolicy.acceptsInMemoryPayload(byteCount: 0))
        #expect(ShareImageImportPolicy.acceptsInMemoryPayload(byteCount: ShareImageImportPolicy.maxInMemoryImageBytes))
    }

    @Test func rejectsPayloadsOutsideBudget() {
        #expect(!ShareImageImportPolicy.acceptsInMemoryPayload(byteCount: -1))
        #expect(
            !ShareImageImportPolicy.acceptsInMemoryPayload(
                byteCount: ShareImageImportPolicy.maxInMemoryImageBytes + 1
            )
        )
    }

    @Test func acceptsSourceFilesWithinTheirIndependentBudget() {
        #expect(ShareImageImportPolicy.acceptsEncodedSourceFile(byteCount: 1))
        #expect(
            ShareImageImportPolicy.acceptsEncodedSourceFile(
                byteCount: ShareImageImportPolicy.maxEncodedSourceFileBytes
            )
        )
    }

    @Test func rejectsEmptyAndOversizedSourceFiles() {
        #expect(!ShareImageImportPolicy.acceptsEncodedSourceFile(byteCount: 0))
        #expect(
            !ShareImageImportPolicy.acceptsEncodedSourceFile(
                byteCount: ShareImageImportPolicy.maxEncodedSourceFileBytes + 1
            )
        )
    }

    @Test func rejectsOversizedFileBeforeAConsumerCopiesIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImageImportPolicyTests-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data([0])))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ShareImageImportPolicy.maxEncodedSourceFileBytes + 1))
        try handle.close()

        #expect(throws: ShareImageImportPolicy.SourceFileError.tooLarge) {
            try ShareImageImportPolicy.validateEncodedSourceFile(at: url)
        }
    }

    @Test func acceptsRegularNonemptyFileWithinSourceBudget() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImageImportPolicyTests-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)

        #expect(try ShareImageImportPolicy.validateEncodedSourceFile(at: url) == 3)
    }
}
