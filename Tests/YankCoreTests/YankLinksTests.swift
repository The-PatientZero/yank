import Testing
@testable import YankCore

@Suite("Public links")
struct YankLinksTests {
    @Test("Privacy policy uses the canonical public HTTPS location")
    func privacyPolicyLocation() {
        let url = YankLinks.privacyPolicy

        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path == "/The-PatientZero/yank/blob/main/PRIVACY.md")
    }
}
