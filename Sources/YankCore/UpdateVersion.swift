import Foundation

/// Pure version comparison for the updater's install gate. Extracted from the macOS
/// `UpdateService` so the rule that decides "is this release newer than what's running"
/// is unit-tested headlessly — it gates every download and every staged install, and a
/// silent regression here would either skip a real update or loop on a stale one.
///
/// The comparison is numeric and dot-separated: each version is split on `.` and the
/// segments that parse as integers are compared left to right, with a missing trailing
/// segment treated as `0` (so `1.2` and `1.2.0` are equal). Non-numeric segments — the
/// `-beta` of `1.2.0-beta`, the `+build` of `1.2.0+build`, or wholesale garbage — do not
/// parse as integers and are simply dropped before comparison. This means pre-release and
/// build suffixes are ignored rather than ordered (`1.2.0-beta` compares equal to `1.2.0`),
/// and a fully malformed string collapses to the empty segment list (treated as all-zero).
/// The updater pairs this with `UpdateReleaseSelection`, which already filters out
/// prereleases upstream, so suffix ordering is intentionally out of scope here.
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

    /// Whether `candidate` should be offered as an update: strictly newer than what's running
    /// AND not below the highest version ever installed on this machine. The floor closes a
    /// downgrade-via-tampered-manifest path — a signed-but-older release the user already moved
    /// past can't be re-offered. Reduces to `isNewer(candidate, current)` in the normal case
    /// where the running app *is* the highest ever installed.
    static func shouldOfferUpdate(candidate: String, current: String, highestInstalled: String) -> Bool {
        isNewer(candidate, than: current) && !isNewer(highestInstalled, than: candidate)
    }

    /// True when a staged update should be offered to install: it is a newer version than the
    /// running app AND its install target is the bundle we expect. Whether the staged payload
    /// still exists on disk is an I/O concern the caller checks separately. Pure so the
    /// staged-update gate is testable in `YankCore`.
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
