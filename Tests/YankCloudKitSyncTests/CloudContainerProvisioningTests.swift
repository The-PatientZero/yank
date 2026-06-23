import Foundation
import Testing
@testable import YankCloudKitSync

@Suite
struct CloudContainerProvisioningTests {
    @Test func findsContainerInArrayEntitlementValue() {
        #expect(CloudContainerProvisioning.contains(
            "iCloud.com.thepatientzero.yank",
            in: ["iCloud.example.other", "iCloud.com.thepatientzero.yank"]
        ))
    }

    @Test func rejectsMissingContainerInArrayEntitlementValue() {
        #expect(!CloudContainerProvisioning.contains(
            "iCloud.com.thepatientzero.yank",
            in: ["iCloud.example.other"]
        ))
    }

    @Test func supportsStringEntitlementValue() {
        #expect(CloudContainerProvisioning.contains(
            "iCloud.com.thepatientzero.yank",
            in: "iCloud.com.thepatientzero.yank"
        ))
    }

    @Test func rejectsUnexpectedEntitlementValueShape() {
        #expect(!CloudContainerProvisioning.contains("iCloud.com.thepatientzero.yank", in: 42))
    }

    @Test func requiresContainerAndCloudKitService() {
        #expect(CloudContainerProvisioning.isProvisioned(
            for: "iCloud.com.thepatientzero.yank",
            containerEntitlement: ["iCloud.com.thepatientzero.yank"],
            serviceEntitlement: ["CloudKit"]
        ))
    }

    @Test func rejectsCloudKitAnonymousService() {
        #expect(!CloudContainerProvisioning.isProvisioned(
            for: "iCloud.com.thepatientzero.yank",
            containerEntitlement: "iCloud.com.thepatientzero.yank",
            serviceEntitlement: "CloudKit-Anonymous"
        ))
    }

    @Test func rejectsProvisioningWhenCloudKitServiceIsMissing() {
        #expect(!CloudContainerProvisioning.isProvisioned(
            for: "iCloud.com.thepatientzero.yank",
            containerEntitlement: ["iCloud.com.thepatientzero.yank"],
            serviceEntitlement: ["iCloudDocuments"]
        ))
    }

    @Test func rejectsProvisioningWhenContainerIsMissing() {
        #expect(!CloudContainerProvisioning.isProvisioned(
            for: "iCloud.com.thepatientzero.yank",
            containerEntitlement: ["iCloud.example.other"],
            serviceEntitlement: ["CloudKit"]
        ))
    }
}
