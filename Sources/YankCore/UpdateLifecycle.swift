import Foundation

struct StagedUpdate: Codable, Equatable, Sendable {
    let version: String
    let tag: String
    let stagedAppPath: String
    let targetAppPath: String
    let stagedAt: Date
    let releaseNotes: String?
    let releaseURL: String?

    init(
        version: String,
        tag: String,
        stagedAppPath: String,
        targetAppPath: String,
        stagedAt: Date,
        releaseNotes: String? = nil,
        releaseURL: String? = nil
    ) {
        self.version = version
        self.tag = tag
        self.stagedAppPath = stagedAppPath
        self.targetAppPath = targetAppPath
        self.stagedAt = stagedAt
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
    }
}

enum UpdateLifecycleState: Equatable, Sendable {
    case idle
    case checking
    case available(version: String, tag: String)
    case downloading(version: String)
    case staged(StagedUpdate)
    case upToDate(version: String)
    case unavailable
    case failed(UpdateFailureContext)
    case installed(version: String, tag: String, releaseNotes: String?, releaseURL: String?)

    var canCheckForUpdates: Bool {
        switch self {
        case .idle, .upToDate, .unavailable, .failed, .installed:
            true
        case .checking, .available, .downloading, .staged:
            false
        }
    }

    var stagedUpdate: StagedUpdate? {
        if case let .staged(update) = self { update } else { nil }
    }

    func canAcceptDownloadedUpdate(version: String) -> Bool {
        if case let .downloading(activeVersion) = self {
            activeVersion == version
        } else {
            false
        }
    }
}

struct UpdateFailureContext: Equatable, Sendable {
    let title: String
    let detail: String
    let version: String?
    let tag: String?
}

enum UpdateMenuActionID: String, Equatable, Sendable {
    case check
    case install
    case cancel
    case retry
    case relaunch
    case openReleaseNotes
}

struct UpdateMenuPresentation: Equatable, Sendable {
    let icon: String
    let title: String
    let trailing: String
    let detail: String
    let isWorking: Bool
    let isActive: Bool
    let action: UpdateMenuActionID?
    let accessibilityHint: String
}

extension UpdateLifecycleState {
    var menuPresentation: UpdateMenuPresentation {
        switch self {
        case .idle:
            return UpdateMenuPresentation(
                icon: "arrow.down.circle",
                title: "Check for updates",
                trailing: "",
                detail: "",
                isWorking: false,
                isActive: false,
                action: .check,
                accessibilityHint: "Checks for a newer Yank release."
            )
        case .checking:
            return UpdateMenuPresentation(
                icon: "clock",
                title: "Checking for updates",
                trailing: "",
                detail: "",
                isWorking: true,
                isActive: false,
                action: nil,
                accessibilityHint: "An update check is already running."
            )
        case let .available(version, tag):
            return UpdateMenuPresentation(
                icon: "arrow.down.circle.fill",
                title: "Install \(version)",
                trailing: "",
                detail: "",
                isWorking: false,
                isActive: !tag.isEmpty,
                action: .install,
                accessibilityHint: "Downloads and stages this update."
            )
        case let .downloading(version):
            return UpdateMenuPresentation(
                icon: "arrow.triangle.2.circlepath",
                title: "Cancel update download",
                trailing: version,
                detail: "",
                isWorking: true,
                isActive: false,
                action: .cancel,
                accessibilityHint: "Cancels the active update download."
            )
        case let .staged(update):
            return UpdateMenuPresentation(
                icon: "checkmark.seal.fill",
                title: "Relaunch \(update.version)",
                trailing: "",
                detail: "Yank is ready to finish installing.",
                isWorking: false,
                isActive: true,
                action: .relaunch,
                accessibilityHint: "Relaunches Yank to finish installing the update."
            )
        case .upToDate(_):
            return UpdateMenuPresentation(
                icon: "checkmark.circle",
                title: "Check again",
                trailing: "Current",
                detail: "",
                isWorking: false,
                isActive: false,
                action: .check,
                accessibilityHint: "Checks again for updates."
            )
        case .unavailable:
            return UpdateMenuPresentation(
                icon: "exclamationmark.triangle.fill",
                title: "Retry update",
                trailing: "Unavailable",
                detail: "",
                isWorking: false,
                isActive: false,
                action: .retry,
                accessibilityHint: "Retries the update check."
            )
        case let .failed(failure):
            return UpdateMenuPresentation(
                icon: "xmark.octagon.fill",
                title: retryTitle(for: failure),
                trailing: failure.version ?? "Failed",
                detail: failure.detail,
                isWorking: false,
                isActive: false,
                action: .retry,
                accessibilityHint: "Retries the failed update step."
            )
        case let .installed(version, tag, releaseNotes, releaseURL):
            let hasReleasePage = UpdateSecurityPolicy.trustedReleasePageURL(from: releaseURL) != nil
            return UpdateMenuPresentation(
                icon: tag.isEmpty ? "checkmark.seal.fill" : "sparkles",
                title: tag.isEmpty ? "Check again" : "What's new in \(version)",
                trailing: tag.isEmpty ? "Updated" : (hasReleasePage ? "Open" : version),
                detail: tag.isEmpty
                    ? ""
                    : UpdateReleaseNotesFormatter.menuDetail(
                        from: releaseNotes,
                        releaseURL: hasReleasePage ? releaseURL : nil,
                        version: version
                    ),
                isWorking: false,
                isActive: !tag.isEmpty,
                action: tag.isEmpty ? .check : (hasReleasePage ? .openReleaseNotes : .check),
                accessibilityHint: tag.isEmpty
                    ? "Checks again for updates."
                    : (hasReleasePage ? "Opens release notes on GitHub." : "Checks again for updates.")
            )
        }
    }

    private func retryTitle(for failure: UpdateFailureContext) -> String {
        if failure.title.contains("relaunch") {
            return "Retry relaunch"
        }
        if failure.version != nil {
            return "Retry update"
        }
        return "Retry update check"
    }
}

enum UpdateReleaseNotesFormatter {
    static func menuDetail(from body: String?, releaseURL: String?, version: String) -> String {
        let lines = plainLines(from: body)
        if !lines.isEmpty {
            return clipped(lines.prefix(3).joined(separator: "\n"), maxLength: 220)
        }
        if let releaseURL, !releaseURL.isEmpty {
            return "Release notes are available on GitHub."
        }
        return "Yank \(version) is installed."
    }

    private static func plainLines(from body: String?) -> [String] {
        guard let body else { return [] }
        return body
            .split(separator: "\n")
            .map(cleanLine)
            .filter { !$0.isEmpty && !isGeneratedChangelogLine($0) && !isSectionHeading($0) }
    }

    private static func cleanLine(_ rawLine: Substring) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        while line.hasPrefix("#") {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while line.hasPrefix("- ") || line.hasPrefix("* ") {
            line.removeFirst(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGeneratedChangelogLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("full changelog") || lower.contains("github.com/") && lower.contains("/compare/")
    }

    private static func isSectionHeading(_ line: String) -> Bool {
        ["what's changed", "whats changed", "new contributors"].contains(line.lowercased())
    }

    private static func clipped(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 3)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
