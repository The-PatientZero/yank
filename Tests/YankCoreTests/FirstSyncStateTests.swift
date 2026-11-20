import Foundation
import Testing
@testable import YankCore

@Suite struct FirstSyncStateTests {
    @Test func failureMessageIsOnlyPresentForFailedState() {
        #expect(FirstSyncState.idle.failureMessage == nil)
        #expect(FirstSyncState.syncing.failureMessage == nil)
        #expect(FirstSyncState.settled.failureMessage == nil)
        #expect(FirstSyncState.failed(message: "CloudKit unavailable").failureMessage == "CloudKit unavailable")
    }
}
