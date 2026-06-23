import Foundation

enum UpdateError: LocalizedError {
    case invalidURL(String)
    case untrustedHost(String)
    case unsupportedReleaseFeed(String)
    case invalidHTTPStatus(Int)
    case releaseManifestDecodeFailed(status: Int?, byteCount: Int)
    case missingChecksum
    case checksumMismatch(expected: String, actual: String)
    case missingBundle
    case bundleIdentifierMismatch(String?)
    case versionMismatch(expected: String, actual: String?)
    case unsafeInstallTarget(String)
    case processFailed(name: String, status: Int32)
    /// Wraps an untyped system error (file system, network, process launch) so the updater's
    /// install path can declare `throws(UpdateError)` without discarding the underlying cause.
    case underlying(operation: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "Invalid update URL: \(value)"
        case let .untrustedHost(host):
            return "Update asset came from an untrusted host: \(host)"
        case let .unsupportedReleaseFeed(url):
            return "Update feed must be a public HTTPS manifest, not a private or authenticated API: \(url)"
        case let .invalidHTTPStatus(status):
            return "Update download failed with HTTP \(status)"
        case let .releaseManifestDecodeFailed(status, byteCount):
            let response = status.map { "HTTP \($0)" } ?? "non-HTTP response"
            return "Could not read release manifest (\(response), \(byteCount) bytes)"
        case .missingChecksum:
            return "Release is missing a SHA-256 checksum"
        case let .checksumMismatch(expected, actual):
            return "Checksum mismatch (expected \(expected), got \(actual))"
        case .missingBundle:
            return "Yank.app was not found in the update"
        case let .bundleIdentifierMismatch(actual):
            return "Updated app has the wrong bundle identifier: \(actual ?? "unknown")"
        case let .versionMismatch(expected, actual):
            return "Updated app version \(actual ?? "unknown") does not match \(expected)"
        case let .unsafeInstallTarget(path):
            return "Update target is not a Yank app bundle: \(path)"
        case let .processFailed(name, status):
            return "\(name) failed with exit \(status)"
        case let .underlying(operation, message):
            return "\(operation) failed: \(message)"
        }
    }
}

enum UpdateSecurityPolicy {
    static func validateReleaseFeedURL(_ url: URL) throws {
        guard url.scheme == "https" else { throw UpdateError.invalidURL(url.absoluteString) }
        guard !isGitHubReleasesAPI(url) else {
            throw UpdateError.unsupportedReleaseFeed(url.absoluteString)
        }
    }

    static func validateReleaseFeedResponse(_ response: URLResponse, expectedURL: URL) throws {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.invalidHTTPStatus(http.statusCode)
        }
        guard response.url?.scheme == "https",
              response.url?.host?.caseInsensitiveCompare(expectedURL.host ?? "") == .orderedSame else {
            throw UpdateError.unsupportedReleaseFeed(response.url?.absoluteString ?? "unknown")
        }
    }

    static func validateReleaseAssetURL(_ url: URL) throws {
        guard url.scheme == "https" else { throw UpdateError.invalidURL(url.absoluteString) }
        guard let host = url.host, isTrustedReleaseHost(host) else {
            throw UpdateError.untrustedHost(url.host ?? "unknown")
        }
    }

    static func validateReleaseAssetResponse(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.invalidHTTPStatus(http.statusCode)
        }
        guard let host = response.url?.host, isTrustedReleaseHost(host) else {
            throw UpdateError.untrustedHost(response.url?.host ?? "unknown")
        }
    }

    static func trustedReleasePageURL(from value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              url.scheme == "https",
              url.host?.caseInsensitiveCompare("github.com") == .orderedSame else {
            return nil
        }
        return url
    }

    static func parseSHA256(from body: String) throws -> String {
        guard let hash = body
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .first(where: { $0.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil })
        else {
            throw UpdateError.missingChecksum
        }
        return hash.lowercased()
    }

    private static func isTrustedReleaseHost(_ host: String) -> Bool {
        host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    private static func isGitHubReleasesAPI(_ url: URL) -> Bool {
        guard url.host == "api.github.com" else { return false }
        let components = url.path.split(separator: "/")
        return components.count >= 4
            && components[0] == "repos"
            && components[3] == "releases"
    }
}
