import CryptoKit
import Foundation

/// Single-quotes a string for safe interpolation into a `/bin/bash` command line, escaping
/// any embedded single quotes. Shared by the updater's install script and the status-bar
/// restart path, which both shell out with a bundle path that the user could in principle
/// control. One home so the quoting rule can't drift between the two call sites.
enum ShellQuoting {
    static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Runs an untyped-throwing system call and folds any failure into `UpdateError`: an error
/// that is already an `UpdateError` is rethrown unchanged, anything else is wrapped in
/// `.underlying` with the operation label so the install path can stay fully typed-throws.
@discardableResult
private func mapUpdateError<T>(
    operation: String,
    _ body: () throws -> T
) throws(UpdateError) -> T {
    do {
        return try body()
    } catch let error as UpdateError {
        throw error
    } catch {
        throw .underlying(operation: operation, message: error.localizedDescription)
    }
}

/// The external commands the installer shells out to — extraction, signature verification,
/// Gatekeeper assessment, and the install script's mode change. Injected so each install gate
/// can be exercised without a signed archive or the machine's real Gatekeeper state; production
/// always uses `.system`.
struct UpdateProcessRunner: Sendable {
    private let execute: @Sendable (String, String, [String]) throws -> Void

    init(_ execute: @escaping @Sendable (String, String, [String]) throws -> Void) {
        self.execute = execute
    }

    /// Folds any untyped launch failure into `UpdateError` so the install path stays fully
    /// typed-throws; an `UpdateError` the command itself raised passes through unchanged.
    func run(_ name: String, _ executable: String, _ arguments: [String]) throws(UpdateError) {
        try mapUpdateError(operation: "Launching \(name)") {
            try execute(name, executable, arguments)
        }
    }

    static let system = UpdateProcessRunner { name, executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.processFailed(name: name, status: process.terminationStatus)
        }
    }
}

enum UpdateInstaller {
    private static let expectedBundleIdentifier = "com.thepatientzero.yank"
    private static let expectedTeamIdentifier = "SCSCVE6L3U"
    private static let hashChunkSize = 1_048_576

    static func fetchExpectedSHA256(from url: URL) async throws(UpdateError) -> String {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw .underlying(operation: "Fetching checksum", message: error.localizedDescription)
        }
        try mapUpdateError(operation: "Validating checksum response") {
            try UpdateSecurityPolicy.validateReleaseAssetResponse(response)
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw .missingChecksum
        }
        return try mapUpdateError(operation: "Parsing checksum") {
            try UpdateSecurityPolicy.parseSHA256(from: body)
        }
    }

    static func stageInstall(
        expectedVersion: String,
        tag: String,
        localURL: URL,
        expectedChecksum: String,
        targetAppURL: URL,
        releaseNotes: String? = nil,
        releaseURL: String? = nil,
        runner: UpdateProcessRunner = .system,
        stagingRootOverride: URL? = nil
    ) throws(UpdateError) -> StagedUpdate {
        let fileManager = FileManager.default
        // Staging clears the whole root, so tests must be able to point it away from the
        // real Application Support tree rather than deleting a user's pending update.
        let updatesRoot = stagingRootOverride ?? stagingRootDirectory(fileManager: fileManager)
        try? fileManager.removeItem(at: updatesRoot)

        let stageDirectory = updatesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipURL = stageDirectory.appendingPathComponent("update.zip")
        let extractURL = stageDirectory.appendingPathComponent("extracted")
        let newAppURL = extractURL.appendingPathComponent("Yank.app")

        try mapUpdateError(operation: "Creating staging directory") {
            try fileManager.createDirectory(
                at: stageDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try mapUpdateError(operation: "Moving download into place") {
            try fileManager.moveItem(at: localURL, to: zipURL)
        }

        let actualChecksum = try sha256Hex(for: zipURL)
        guard actualChecksum == expectedChecksum else {
            throw .checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }

        try runner.run("ditto", "/usr/bin/ditto", ["-xk", zipURL.path, extractURL.path])

        guard fileManager.fileExists(atPath: newAppURL.path) else { throw .missingBundle }
        try validateBundle(at: newAppURL, expectedVersion: expectedVersion)
        try verifyCodeSignature(at: newAppURL, runner: runner)
        try assessWithGatekeeper(newAppURL, runner: runner)

        return StagedUpdate(
            version: expectedVersion,
            tag: tag,
            stagedAppPath: newAppURL.path,
            targetAppPath: targetAppURL.path,
            stagedAt: Date(),
            releaseNotes: releaseNotes,
            releaseURL: releaseURL
        )
    }

    static func launchStagedInstall(
        _ staged: StagedUpdate,
        runner: UpdateProcessRunner = .system
    ) throws(UpdateError) {
        let fileManager = FileManager.default
        let stagedAppURL = URL(fileURLWithPath: staged.stagedAppPath)
        let targetAppURL = URL(fileURLWithPath: staged.targetAppPath)
        let stageDirectory = stagedAppURL.deletingLastPathComponent().deletingLastPathComponent()
        let scriptURL = stageDirectory.appendingPathComponent("install.sh")
        let backupURL = URL(fileURLWithPath: "\(targetAppURL.path).previous-update")

        try validateTargetAppURL(targetAppURL)
        guard fileManager.fileExists(atPath: stagedAppURL.path) else { throw .missingBundle }
        try validateBundle(at: stagedAppURL, expectedVersion: staged.version)
        try verifyCodeSignature(at: stagedAppURL, runner: runner)
        try assessWithGatekeeper(stagedAppURL, runner: runner)

        let script = """
        #!/bin/bash
        set -euo pipefail

        staged_app=\(ShellQuoting.quoted(stagedAppURL.path))
        target_app=\(ShellQuoting.quoted(targetAppURL.path))
        backup_app=\(ShellQuoting.quoted(backupURL.path))

        restore_backup() {
            if [ -d "$backup_app" ] && [ ! -d "$target_app" ]; then
                /bin/mv "$backup_app" "$target_app"
            fi
        }

        trap restore_backup ERR
        sleep 1

        if [ -d "$backup_app" ]; then
            /bin/rm -R "$backup_app"
        fi

        if [ -d "$target_app" ]; then
            /bin/mv "$target_app" "$backup_app"
        fi

        /bin/cp -R "$staged_app" "$target_app"
        /usr/bin/xattr -cr "$target_app" || true
        /bin/launchctl asuser "$(id -u)" /usr/bin/open "$target_app"

        if [ -d "$backup_app" ]; then
            /bin/rm -R "$backup_app"
        fi
        """
        try mapUpdateError(operation: "Writing install script") {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }

        try runner.run("chmod", "/bin/chmod", ["755", scriptURL.path])
        try runner.run(
            "installer launcher",
            "/bin/sh",
            ["-c", "nohup /bin/bash \(ShellQuoting.quoted(scriptURL.path)) >/dev/null 2>&1 &"]
        )
    }

    static func removeStagedUpdate(_ staged: StagedUpdate) {
        let stagedAppURL = URL(fileURLWithPath: staged.stagedAppPath)
        let stageDirectory = stagedAppURL.deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: stageDirectory)
    }

    private static func stagingRootDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Yank", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    private static func validateTargetAppURL(_ targetAppURL: URL) throws(UpdateError) {
        guard targetAppURL.lastPathComponent == "Yank.app" else {
            throw .unsafeInstallTarget(targetAppURL.path)
        }
    }

    private static func sha256Hex(for fileURL: URL) throws(UpdateError) -> String {
        var hasher = SHA256()
        let handle = try mapUpdateError(operation: "Opening download for hashing") {
            try FileHandle(forReadingFrom: fileURL)
        }
        defer { try? handle.close() }

        while true {
            let chunk = try mapUpdateError(operation: "Reading download for hashing") {
                try handle.read(upToCount: Self.hashChunkSize)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateBundle(at appURL: URL, expectedVersion: String) throws(UpdateError) {
        guard let bundle = Bundle(url: appURL) else { throw .missingBundle }
        guard bundle.bundleIdentifier == Self.expectedBundleIdentifier else {
            throw .bundleIdentifierMismatch(bundle.bundleIdentifier)
        }
        let actualVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        guard actualVersion == expectedVersion else {
            throw .versionMismatch(expected: expectedVersion, actual: actualVersion)
        }
    }

    private static func verifyCodeSignature(
        at appURL: URL,
        runner: UpdateProcessRunner
    ) throws(UpdateError) {
        let requirement = [
            "anchor apple generic",
            "certificate leaf[subject.OU] = \"\(Self.expectedTeamIdentifier)\"",
            "identifier \"\(Self.expectedBundleIdentifier)\""
        ].joined(separator: " and ")
        try runner.run(
            "codesign",
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "-R=\(requirement)", appURL.path]
        )
    }

    private static func assessWithGatekeeper(
        _ appURL: URL,
        runner: UpdateProcessRunner
    ) throws(UpdateError) {
        try runner.run(
            "spctl",
            "/usr/sbin/spctl",
            ["-a", "-t", "execute", "-vv", appURL.path]
        )
    }
}
