import Foundation
import Testing
@testable import YankCore

@Suite struct UpdateReleaseSelectionTests {
    private func asset(_ name: String) -> UpdateAsset {
        UpdateAsset(name: name, downloadURL: "https://example.com/\(name)")
    }

    private func release(
        tag: String,
        prerelease: Bool = false,
        publishedAt: String?,
        htmlURL: String? = nil,
        body: String? = nil,
        assets: [UpdateAsset]
    ) -> UpdateRelease {
        UpdateRelease(
            tagName: tag,
            prerelease: prerelease,
            publishedAt: publishedAt,
            htmlURL: htmlURL ?? "https://github.com/The-PatientZero/yank/releases/tag/\(tag)",
            body: body,
            assets: assets
        )
    }

    @Test func picksNewestNonPrereleaseWithArchZipAndChecksum() {
        let releases = [
            release(tag: "v1.0.0", publishedAt: "2026-01-01T00:00:00Z", assets: [
                asset("Yank-1.0.0-Silicon.zip"), asset("Yank-1.0.0-Silicon.zip.sha256"),
            ]),
            release(tag: "v2.0.0", publishedAt: "2026-02-01T00:00:00Z", assets: [
                asset("Yank-2.0.0-Silicon.zip"), asset("Yank-2.0.0-Silicon.zip.sha256"),
                asset("Yank-2.0.0-Intel.zip"), asset("Yank-2.0.0-Intel.zip.sha256"),
            ]),
        ]
        let candidate = UpdateReleaseSelection.newestCandidate(from: releases, archKeyword: "Silicon")
        #expect(candidate?.tag == "v2.0.0")
        #expect(candidate?.downloadURL == "https://example.com/Yank-2.0.0-Silicon.zip")
        #expect(candidate?.checksumURL == "https://example.com/Yank-2.0.0-Silicon.zip.sha256")
        #expect(candidate?.releaseURL == "https://github.com/The-PatientZero/yank/releases/tag/v2.0.0")
    }

    @Test func skipsPrereleases() {
        let releases = [
            release(tag: "v3.0.0-beta", prerelease: true, publishedAt: "2026-03-01T00:00:00Z", assets: [
                asset("Yank-3.0.0-Silicon.zip"), asset("Yank-3.0.0-Silicon.zip.sha256"),
            ]),
            release(tag: "v2.0.0", publishedAt: "2026-02-01T00:00:00Z", assets: [
                asset("Yank-2.0.0-Silicon.zip"), asset("Yank-2.0.0-Silicon.zip.sha256"),
            ]),
        ]
        #expect(UpdateReleaseSelection.newestCandidate(from: releases, archKeyword: "Silicon")?.tag == "v2.0.0")
    }

    @Test func requiresAMatchingChecksumAsset() {
        // A ZIP with no paired .sha256 is not a valid candidate — the updater fails closed.
        let releases = [release(tag: "v1.0.0", publishedAt: "2026-01-01T00:00:00Z",
                                assets: [asset("Yank-1.0.0-Silicon.zip")])]
        #expect(UpdateReleaseSelection.newestCandidate(from: releases, archKeyword: "Silicon") == nil)
    }

    @Test func fallsBackToAnyZipWhenArchAssetMissing() {
        let releases = [release(tag: "v1.0.0", publishedAt: "2026-01-01T00:00:00Z", assets: [
            asset("Yank-1.0.0-Intel.zip"), asset("Yank-1.0.0-Intel.zip.sha256"),
        ])]
        let candidate = UpdateReleaseSelection.newestCandidate(from: releases, archKeyword: "Silicon")
        #expect(candidate?.downloadURL == "https://example.com/Yank-1.0.0-Intel.zip")
    }

    @Test func untrustedReleasePageDoesNotBlockInstallCandidate() {
        let releases = [release(tag: "v1.0.0",
                                publishedAt: "2026-01-01T00:00:00Z",
                                htmlURL: "https://example.com/yank/releases/tag/v1.0.0",
                                assets: [
                                    asset("Yank-1.0.0-Silicon.zip"),
                                    asset("Yank-1.0.0-Silicon.zip.sha256"),
                                ])]
        let candidate = UpdateReleaseSelection.newestCandidate(from: releases, archKeyword: "Silicon")
        #expect(candidate?.tag == "v1.0.0")
        #expect(candidate?.releaseURL == nil)
    }

    @Test func decodesGitHubReleaseJSON() throws {
        let json = """
        [{"tag_name":"v1.2.0","prerelease":false,"published_at":"2026-01-01T00:00:00Z",
          "html_url":"https://github.com/The-PatientZero/yank/releases/tag/v1.2.0",
          "body":"- Inline update notes",
          "assets":[{"name":"Yank-1.2.0-Silicon.zip","browser_download_url":"https://x/y.zip"}]}]
        """
        let releases = try JSONDecoder().decode([UpdateRelease].self, from: Data(json.utf8))
        #expect(releases.first?.tagName == "v1.2.0")
        #expect(releases.first?.htmlURL == "https://github.com/The-PatientZero/yank/releases/tag/v1.2.0")
        #expect(releases.first?.body == "- Inline update notes")
        #expect(releases.first?.assets.first?.downloadURL == "https://x/y.zip")
    }
}
