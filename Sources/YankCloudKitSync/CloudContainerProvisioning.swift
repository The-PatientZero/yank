import Foundation
#if os(macOS)
import Security
#endif

/// Reads process entitlements without constructing `CKContainer` — asking for an unprovisioned
/// iCloud container can abort the process, so callers gate CloudKit wiring through this helper
/// before constructing `CKContainer(identifier:)`.
public enum CloudContainerProvisioning {
    private static let containerEntitlementKey = "com.apple.developer.icloud-container-identifiers"
    private static let serviceEntitlementKey = "com.apple.developer.icloud-services"
    private static let cloudKitService = "CloudKit"

    public static func isProvisioned(for containerIdentifier: String) -> Bool {
        #if os(macOS)
        guard let containerEntitlement = entitlementValue(for: containerEntitlementKey),
              let serviceEntitlement = entitlementValue(for: serviceEntitlementKey) else {
            return false
        }
        return isProvisioned(
            for: containerIdentifier,
            containerEntitlement: containerEntitlement,
            serviceEntitlement: serviceEntitlement
        )
        #elseif targetEnvironment(simulator)
        // Unsigned simulator runs do not carry CloudKit/App Group entitlements; constructing
        // `CKContainer(identifier:)` traps before the app can show its local-only UI.
        return false
        #else
        // Physical iOS installs are signed/provisioned by the owner team. iOS does not expose
        // the same public SecTask entitlement inspection API available to the macOS target.
        return true
        #endif
    }

    public static func isProvisioned(
        for containerIdentifier: String,
        containerEntitlement: Any,
        serviceEntitlement: Any
    ) -> Bool {
        contains(containerIdentifier, in: containerEntitlement)
            && contains(cloudKitService, in: serviceEntitlement)
    }

    private static func entitlementValue(for key: String) -> Any? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
            return nil
        }
        return value
        #else
        return nil
        #endif
    }

    public static func contains(_ containerIdentifier: String, in entitlementValue: Any) -> Bool {
        if let containers = entitlementValue as? [String] {
            return containers.contains(containerIdentifier)
        }
        if let container = entitlementValue as? String {
            return container == containerIdentifier
        }
        return false
    }
}
