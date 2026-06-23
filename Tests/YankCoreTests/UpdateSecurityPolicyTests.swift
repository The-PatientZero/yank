import Foundation
import Testing
@testable import YankCore

@Suite struct UpdateSecurityPolicyTests {
    @Test func allowsPublicHTTPSReleaseFeedOutsideGitHubAPI() throws {
        try UpdateSecurityPolicy.validateReleaseFeedURL(
            #require(URL(string: "https://raw.githubusercontent.com/The-PatientZero/yank/main/releases.json"))
        )
    }

    @Test func rejectsPrivateOrAuthenticatedGitHubReleaseAPIAsFeed() throws {
        expectUpdateError("non-HTTPS release feed should fail as an invalid URL") { error in
            if case .invalidURL("http://updates.example.com/releases.json") = error { true } else { false }
        } operation: {
            try UpdateSecurityPolicy.validateReleaseFeedURL(
                #require(URL(string: "http://updates.example.com/releases.json"))
            )
        }
        expectUpdateError("private GitHub API feed should fail as unsupported") { error in
            if case .unsupportedReleaseFeed("https://api.github.com/repos/The-PatientZero/yank/releases") = error {
                true
            } else {
                false
            }
        } operation: {
            try UpdateSecurityPolicy.validateReleaseFeedURL(
                #require(URL(string: "https://api.github.com/repos/The-PatientZero/yank/releases"))
            )
        }
    }

    @Test func validatesReleaseFeedResponseStaysOnConfiguredHTTPSHost() throws {
        let feedURL = try #require(URL(string: "https://updates.example.com/releases.json"))
        let response = try #require(
            HTTPURLResponse(
                url: feedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        try UpdateSecurityPolicy.validateReleaseFeedResponse(response, expectedURL: feedURL)

        let redirectedURL = try #require(URL(string: "https://example.com/releases.json"))
        let redirected = try #require(
            HTTPURLResponse(
                url: redirectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        expectUpdateError("redirected release feed host should fail closed") { error in
            if case .unsupportedReleaseFeed("https://example.com/releases.json") = error { true } else { false }
        } operation: {
            try UpdateSecurityPolicy.validateReleaseFeedResponse(redirected, expectedURL: feedURL)
        }
    }

    @Test func allowsTrustedGithubReleaseHostsOverHTTPS() throws {
        try UpdateSecurityPolicy.validateReleaseAssetURL(#require(URL(string: "https://github.com/x/y/releases/a.zip")))
        try UpdateSecurityPolicy.validateReleaseAssetURL(
            #require(URL(string: "https://objects.githubusercontent.com/a.zip"))
        )
    }

    @Test func rejectsUntrustedOrNonHTTPSReleaseURLs() throws {
        expectUpdateError("non-HTTPS asset URL should fail as invalid") { error in
            if case .invalidURL("http://github.com/x/y/releases/a.zip") = error { true } else { false }
        } operation: {
            try UpdateSecurityPolicy.validateReleaseAssetURL(
                #require(URL(string: "http://github.com/x/y/releases/a.zip"))
            )
        }
        expectUpdateError("untrusted asset host should fail as untrusted") { error in
            if case .untrustedHost("example.com") = error { true } else { false }
        } operation: {
            try UpdateSecurityPolicy.validateReleaseAssetURL(
                #require(URL(string: "https://example.com/a.zip"))
            )
        }
    }

    @Test func trustsOnlyHTTPSGitHubReleasePages() throws {
        let releasePage = try #require(UpdateSecurityPolicy.trustedReleasePageURL(
            from: "https://github.com/The-PatientZero/yank/releases/tag/v1.2.0"
        ))
        #expect(releasePage.host == "github.com")

        #expect(UpdateSecurityPolicy.trustedReleasePageURL(from: "http://github.com/x/y/releases/tag/v1") == nil)
        #expect(UpdateSecurityPolicy.trustedReleasePageURL(from: "https://example.com/x/y/releases/tag/v1") == nil)
        #expect(UpdateSecurityPolicy.trustedReleasePageURL(from: "not a url") == nil)
    }

    @Test func parsesChecksumBody() throws {
        let checksum = "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
        #expect(try UpdateSecurityPolicy.parseSHA256(from: "\(checksum)  Yank.zip") == checksum.lowercased())
    }

    @Test func rejectsMissingChecksum() {
        expectUpdateError("checksum parser should fail specifically on missing checksum") { error in
            if case .missingChecksum = error { true } else { false }
        } operation: {
            _ = try UpdateSecurityPolicy.parseSHA256(from: "no checksum here")
        }
    }

    @Test func describesReleaseManifestDecodeFailure() {
        let error = UpdateError.releaseManifestDecodeFailed(status: 200, byteCount: 42)
        #expect(
            error.errorDescription == "Could not read release manifest (HTTP 200, 42 bytes)"
        )
    }

    @Test func describesUnsupportedReleaseFeed() {
        let error = UpdateError.unsupportedReleaseFeed("https://api.github.com/repos/The-PatientZero/yank/releases")
        #expect(
            error.errorDescription ==
                "Update feed must be a public HTTPS manifest, not a private or authenticated API: " +
                "https://api.github.com/repos/The-PatientZero/yank/releases"
        )
    }

    private func expectUpdateError(
        _ message: String,
        matching isExpected: (UpdateError) -> Bool,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected UpdateError: \(message)")
        } catch let error as UpdateError {
            #expect(isExpected(error), Comment(rawValue: "Unexpected UpdateError for: \(message)"))
        } catch {
            Issue.record("Expected UpdateError for \(message), got \(type(of: error)): \(error)")
        }
    }
}
