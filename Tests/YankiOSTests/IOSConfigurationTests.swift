import Foundation
import Testing

@Suite("iOS configuration")
struct IOSConfigurationTests {
    @Test("iPhone and iPad support every interface orientation")
    func supportedOrientations() throws {
        let plistURL = repositoryURL.appendingPathComponent("iOS/App-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let expected = Set([
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
        ])

        #expect(Set(try #require(plist["UISupportedInterfaceOrientations"] as? [String])) == expected)
        #expect(Set(try #require(plist["UISupportedInterfaceOrientations~ipad"] as? [String])) == expected)
    }

    @Test("Keyboard does not request Full Access")
    func keyboardDoesNotRequestOpenAccess() throws {
        let plist = try propertyList(at: repositoryURL.appendingPathComponent("iOS/Keyboard-Info.plist"))
        let extensionDictionary = try #require(plist["NSExtension"] as? [String: Any])
        let attributes = try #require(extensionDictionary["NSExtensionAttributes"] as? [String: Any])

        #expect(attributes["RequestsOpenAccess"] as? Bool == false)
    }

    @Test("Privacy manifests declare target-accurate UserDefaults reasons")
    func privacyManifestReasons() throws {
        let macReasons = try accessedAPIReasons(
            at: repositoryURL.appendingPathComponent("Privacy/Yank/PrivacyInfo.xcprivacy")
        )
        let iosReasons = try accessedAPIReasons(
            at: repositoryURL.appendingPathComponent("Privacy/YankiOS/PrivacyInfo.xcprivacy")
        )
        let extensionReasons = try accessedAPIReasons(
            at: repositoryURL.appendingPathComponent("Privacy/Extensions/PrivacyInfo.xcprivacy")
        )

        #expect(macReasons == Set(["CA92.1"]))
        #expect(iosReasons == Set(["CA92.1", "1C8F.1"]))
        #expect(extensionReasons.isEmpty)
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func accessedAPIReasons(at url: URL) throws -> Set<String> {
        let plist = try propertyList(at: url)
        let apiTypes = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        return Set(apiTypes.flatMap { $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [] })
    }
}
