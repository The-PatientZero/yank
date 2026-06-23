import Testing
@testable import YankCloudKitSync

@Suite struct CloudKitSyncStartResultTests {
    @Test func startResultCarriesFailureReason() {
        #expect(CloudKitSyncStartResult.started == .started)
        #expect(
            CloudKitSyncStartResult.failed(message: "Missing entitlement") == .failed(message: "Missing entitlement")
        )
    }
}
