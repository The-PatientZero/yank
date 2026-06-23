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
        #expect(!ShareImageImportPolicy.acceptsInMemoryPayload(byteCount: ShareImageImportPolicy.maxInMemoryImageBytes + 1))
    }
}
