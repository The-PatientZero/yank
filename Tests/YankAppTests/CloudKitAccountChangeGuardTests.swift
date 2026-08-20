import Foundation
import Testing
@testable import Yank

@Suite("CloudKit account change guard")
@MainActor
struct CloudKitAccountChangeGuardTests {
    private let containerIdentifier = "test.container"
    private let defaultsKey = "test.accountIdentity"

    @Test("A changed identity resets checkpoints and persists the new identity")
    func changedIdentityResetsAndPersists() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CloudKitAccountChangeGuardTests.\(UUID().uuidString)"))
        defaults.set("old-user", forKey: defaultsKey)
        var resetContainerIDs: [String] = []

        let didReset = await CloudKitAccountChangeGuard.resetIfAccountChanged(
            containerIdentifier: containerIdentifier,
            defaultsKey: defaultsKey,
            defaults: defaults,
            resolveIdentity: { "new-user" },
            resetPersistedState: { id, _ in resetContainerIDs.append(id) }
        )

        #expect(didReset)
        #expect(resetContainerIDs == [containerIdentifier])
        #expect(defaults.string(forKey: defaultsKey) == "new-user")
    }

    @Test("An unchanged identity does not reset")
    func unchangedIdentityDoesNotReset() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CloudKitAccountChangeGuardTests.\(UUID().uuidString)"))
        defaults.set("same-user", forKey: defaultsKey)
        var resetCount = 0

        let didReset = await CloudKitAccountChangeGuard.resetIfAccountChanged(
            containerIdentifier: containerIdentifier,
            defaultsKey: defaultsKey,
            defaults: defaults,
            resolveIdentity: { "same-user" },
            resetPersistedState: { _, _ in resetCount += 1 }
        )

        #expect(!didReset)
        #expect(resetCount == 0)
        #expect(defaults.string(forKey: defaultsKey) == "same-user")
    }

    @Test("A first run only records the identity")
    func firstRunOnlyRecordsIdentity() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CloudKitAccountChangeGuardTests.\(UUID().uuidString)"))
        var resetCount = 0

        let didReset = await CloudKitAccountChangeGuard.resetIfAccountChanged(
            containerIdentifier: containerIdentifier,
            defaultsKey: defaultsKey,
            defaults: defaults,
            resolveIdentity: { "first-user" },
            resetPersistedState: { _, _ in resetCount += 1 }
        )

        #expect(!didReset)
        #expect(resetCount == 0)
        #expect(defaults.string(forKey: defaultsKey) == "first-user")
    }

    @Test("A failed probe leaves the persisted identity and checkpoints untouched")
    func failedProbeLeavesStateUnchanged() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CloudKitAccountChangeGuardTests.\(UUID().uuidString)"))
        defaults.set("existing-user", forKey: defaultsKey)
        var resetCount = 0

        let didReset = await CloudKitAccountChangeGuard.resetIfAccountChanged(
            containerIdentifier: containerIdentifier,
            defaultsKey: defaultsKey,
            defaults: defaults,
            resolveIdentity: { throw CloudKitAccountChangeGuardTestError.probeFailed },
            resetPersistedState: { _, _ in resetCount += 1 }
        )

        #expect(!didReset)
        #expect(resetCount == 0)
        #expect(defaults.string(forKey: defaultsKey) == "existing-user")
    }
}

private enum CloudKitAccountChangeGuardTestError: Error {
    case probeFailed
}
