import Foundation

/// Pure numeric, dot-separated version comparison for the updater's install gate: `1.2` and `1.2.0`
/// compare equal, and non-numeric suffixes (`-beta`, `+build`) are dropped rather than ordered —
/// relying on `UpdateReleaseSelection` already filtering prereleases upstream.
enum UpdateVersion {
    /// Whether `latest` is strictly newer than `current` under the numeric, dot-separated
    /// rule documented above. Equal versions return `false` (no update offered).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let latestParts = numericParts(of: latest)
        let currentParts = numericParts(of: current)
        for index in 0 ..< max(latestParts.count, currentParts.count) {
            let latestPart = index < latestParts.count ? latestParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if latestPart > currentPart { return true }
            if latestPart < currentPart { return false }
        }
        return false
    }

    /// Offered only when `candidate` is strictly newer than `current` AND not below the highest
    /// version ever installed — the floor blocks a downgrade-via-tampered-manifest path, so a
    /// signed-but-older release the user already moved past can't be re-offered.
    static func shouldOfferUpdate(candidate: String, current: String, highestInstalled: String) -> Bool {
        isNewer(candidate, than: current) && !isNewer(highestInstalled, than: candidate)
    }

    /// True when a staged update should install: newer than the running app AND its install
    /// target is the expected bundle. Whether the staged payload still exists on disk is an
    /// I/O concern the caller checks separately.
    static func stagedUpdateApplies(
        stagedVersion: String,
        currentVersion: String,
        targetAppName: String,
        expectedAppName: String = "Yank.app"
    ) -> Bool {
        isNewer(stagedVersion, than: currentVersion) && targetAppName == expectedAppName
    }

    private static func numericParts(of version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
}
