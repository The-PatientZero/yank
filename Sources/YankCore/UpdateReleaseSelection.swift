import Foundation

/// A GitHub release as Yank's updater consumes it — decoded straight from the releases
/// API instead of spelunking an untyped `[[String: Any]]`.
struct UpdateRelease: Decodable, Equatable {
    let tagName: String
    let prerelease: Bool
    let publishedAt: String?
    let htmlURL: String?
    let body: String?
    let assets: [UpdateAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case publishedAt = "published_at"
        case htmlURL = "html_url"
        case body
        case assets
    }

    init(
        tagName: String,
        prerelease: Bool,
        publishedAt: String?,
        htmlURL: String? = nil,
        body: String? = nil,
        assets: [UpdateAsset]
    ) {
        self.tagName = tagName
        self.prerelease = prerelease
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
        self.body = body
        self.assets = assets
    }
}

struct UpdateAsset: Decodable, Equatable {
    let name: String
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

/// Pure selection of the newest non-prerelease release that ships a signed ZIP plus its
/// matching SHA-256 checksum, preferring the asset for the running architecture. No I/O,
/// so it unit-tests headlessly — the part of the updater most likely to rot silently.
enum UpdateReleaseSelection {
    struct Candidate: Equatable {
        let tag: String
        let downloadURL: String
        let checksumURL: String
        let releaseURL: String?
        let releaseNotes: String?
    }

    static func newestCandidate(from releases: [UpdateRelease], archKeyword: String) -> Candidate? {
        let sorted = releases
            .filter { !$0.prerelease }
            .sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }

        for release in sorted {
            let archZip = release.assets.first { $0.name.hasSuffix(".zip") && $0.name.contains(archKeyword) }
            let anyZip = release.assets.first { $0.name.hasSuffix(".zip") }
            guard let zip = archZip ?? anyZip,
                  let checksumURL = checksumURL(for: zip.name, in: release.assets) else { continue }
            return Candidate(
                tag: release.tagName,
                downloadURL: zip.downloadURL,
                checksumURL: checksumURL,
                releaseURL: UpdateSecurityPolicy.trustedReleasePageURL(from: release.htmlURL)?.absoluteString,
                releaseNotes: release.body
            )
        }
        return nil
    }

    /// The download URL of the `.sha256` asset that pairs with `zipName`, if present.
    static func checksumURL(for zipName: String, in assets: [UpdateAsset]) -> String? {
        let expected = [
            "\(zipName).sha256",
            "\(zipName).sha256.txt",
            zipName.replacingOccurrences(of: ".zip", with: ".sha256"),
            zipName.replacingOccurrences(of: ".zip", with: ".sha256.txt"),
        ]
        return assets.first { expected.contains($0.name) }?.downloadURL
    }
}
