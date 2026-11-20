import Foundation
import Testing
@testable import YankCore

@Suite struct DeviceIdentityTests {
    private let deviceIDKey = "yank.deviceID"
    private let generatedUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let secondUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test func identifierIsStableAcrossCalls() throws {
        try withTemporaryDefaults { defaults in
            let first = DeviceIdentity.identifier(in: defaults) { generatedUUID }
            let second = DeviceIdentity.identifier(in: defaults) { secondUUID }

            #expect(first == generatedUUID.uuidString)
            #expect(second == first)
        }
    }

    @Test func identifierIsNonEmpty() throws {
        try withTemporaryDefaults { defaults in
            #expect(!DeviceIdentity.identifier(in: defaults) { generatedUUID }.isEmpty)
        }
    }

    @Test func identifierIsAValidUUIDString() throws {
        try withTemporaryDefaults { defaults in
            #expect(UUID(uuidString: DeviceIdentity.identifier(in: defaults) { generatedUUID }) != nil)
        }
    }

    @Test func identifierUsesCanonicalUppercaseUUIDFormat() throws {
        try withTemporaryDefaults { defaults in
            let id = DeviceIdentity.identifier(in: defaults) { generatedUUID }

            #expect(id.count == 36)
            #expect(id == id.uppercased())
            #expect(id.filter { $0 == "-" }.count == 4)
        }
    }

    @Test func identifierIsPersistedInInjectedDefaults() throws {
        try withTemporaryDefaults { defaults in
            let observed = DeviceIdentity.identifier(in: defaults) { generatedUUID }
            let stored = defaults.string(forKey: deviceIDKey)

            #expect(stored == observed)
        }
    }

    @Test func identifierReusesPersistedValue() throws {
        try withTemporaryDefaults { defaults in
            let persisted = "existing-device"
            defaults.set(persisted, forKey: deviceIDKey)

            let observed = DeviceIdentity.identifier(in: defaults) { generatedUUID }

            #expect(observed == persisted)
            #expect(defaults.string(forKey: deviceIDKey) == persisted)
        }
    }

    @Test func identifierReplacesEmptyPersistedValue() throws {
        try withTemporaryDefaults { defaults in
            defaults.set("", forKey: deviceIDKey)

            let observed = DeviceIdentity.identifier(in: defaults) { generatedUUID }

            #expect(observed == generatedUUID.uuidString)
            #expect(defaults.string(forKey: deviceIDKey) == generatedUUID.uuidString)
        }
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "DeviceIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try body(defaults)
    }
}
