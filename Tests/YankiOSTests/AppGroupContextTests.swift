import Foundation
import Testing
@testable import YankiOS

@Suite struct AppGroupContextTests {
    @Test func derivesEverySharedPathFromInjectedContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppGroupContextTests-\(UUID().uuidString)", isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: "AppGroupContextTests.\(UUID().uuidString)"))
        let context = AppGroupContext(containerURL: root, defaults: defaults)

        #expect(context.historyURL.deletingLastPathComponent() == root)
        #expect(context.tombstonesURL.deletingLastPathComponent() == root)
        #expect(context.blobsURL.deletingLastPathComponent() == root)
        #expect(context.keyboardProjectionURL.deletingLastPathComponent() == root)
        #expect(context.shareInbox.rootURL == root)
    }

    @Test func identifierRemainsCompatibleWithShippedEntitlements() {
        #expect(AppGroupContext.identifier == "group.com.thepatientzero.yank")
    }
}
