import CryptoKit
import Foundation
import Testing
@testable import Yank

@Suite("Shell quoting")
struct ShellQuotingTests {
    @Test("A plain path is wrapped without alteration")
    func plainPath() {
        #expect(ShellQuoting.quoted("/Applications/Yank.app") == "'/Applications/Yank.app'")
    }

    @Test("Spaces and shell metacharacters stay inside the quotes")
    func metacharactersAreInert() {
        #expect(ShellQuoting.quoted("/Volumes/My Disk/Yank.app") == "'/Volumes/My Disk/Yank.app'")
        #expect(ShellQuoting.quoted("a; rm -rf /") == "'a; rm -rf /'")
        #expect(ShellQuoting.quoted("$(whoami)") == "'$(whoami)'")
        #expect(ShellQuoting.quoted("`id`") == "'`id`'")
    }

    /// The one case single quoting cannot handle naively: the quote must close the literal,
    /// escape itself outside it, then reopen. Anything else lets the rest of the path escape
    /// into the surrounding command.
    @Test("An embedded single quote is closed, escaped, and reopened")
    func embeddedSingleQuote() {
        #expect(ShellQuoting.quoted("it's") == #"'it'\''s'"#)
        #expect(ShellQuoting.quoted("'") == #"''\'''"#)
        #expect(ShellQuoting.quoted("a'b'c") == #"'a'\''b'\''c'"#)
    }

    @Test("Newlines and empty input stay quoted")
    func newlinesAndEmptyInput() {
        #expect(ShellQuoting.quoted("line\nbreak") == "'line\nbreak'")
        #expect(ShellQuoting.quoted("") == "''")
    }
}

/// Records every command the installer attempts, and stands in for `ditto` by writing the
/// bundle a real extraction would have produced into the path `ditto` was told to use.
private final class RecordingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    var invoked: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func makeRunner(
        extracting bundle: (identifier: String, version: String)? = nil,
        failing: String? = nil
    ) -> UpdateProcessRunner {
        UpdateProcessRunner { [self] name, _, arguments in
            lock.lock()
            names.append(name)
            lock.unlock()

            // `ditto -xk <zip> <extractPath>`: take the destination from the call itself,
            // because staging picks a fresh UUID directory the test cannot predict.
            if name == "ditto", let bundle, arguments.count >= 3 {
                let appURL = URL(fileURLWithPath: arguments[2]).appendingPathComponent("Yank.app")
                do {
                    try Self.writeAppBundle(
                        at: appURL,
                        identifier: bundle.identifier,
                        version: bundle.version
                    )
                } catch {
                    throw UpdateError.underlying(
                        operation: "Test extraction",
                        message: "\(error)"
                    )
                }
            }
            if name == failing {
                throw UpdateError.processFailed(name: name, status: 1)
            }
        }
    }

    private static func writeAppBundle(at url: URL, identifier: String, version: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleName": "Yank",
            "CFBundleExecutable": "Yank",
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

@Suite("Update installer gates")
struct UpdateInstallerTests {
    private struct Fixture {
        let root: URL
        let stagingRoot: URL
        let download: URL
        let checksum: String
        let target: URL
    }

    private func makeFixture(payload: String = "yank-update-payload") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let download = root.appendingPathComponent("download.zip")
        let bytes = Data(payload.utf8)
        try bytes.write(to: download)
        // A one-shot digest, so the installer's chunked streaming hasher has to agree with it.
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Fixture(
            root: root,
            stagingRoot: root.appendingPathComponent("Updates", isDirectory: true),
            download: download,
            checksum: checksum,
            target: root.appendingPathComponent("Yank.app")
        )
    }

    private func remove(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func stage(
        _ fixture: Fixture,
        expectedVersion: String = "1.2.0",
        expectedChecksum: String? = nil,
        runner: UpdateProcessRunner
    ) throws -> StagedUpdate {
        try UpdateInstaller.stageInstall(
            expectedVersion: expectedVersion,
            tag: "v\(expectedVersion)",
            localURL: fixture.download,
            expectedChecksum: expectedChecksum ?? fixture.checksum,
            targetAppURL: fixture.target,
            runner: runner,
            stagingRootOverride: fixture.stagingRoot
        )
    }

    // MARK: - Gates

    @Test("A mismatched checksum stops the install before anything is extracted")
    func checksumMismatchStopsBeforeExtraction() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()

        let error = #expect(throws: UpdateError.self) {
            try stage(
                fixture,
                expectedChecksum: String(repeating: "0", count: 64),
                runner: recorder.makeRunner()
            )
        }

        guard case .checksumMismatch = error else {
            Issue.record("Expected a checksum mismatch, got \(String(describing: error))")
            return
        }
        #expect(recorder.invoked.isEmpty, "Extraction ran despite a checksum mismatch")
    }

    @Test("A payload whose archive holds no Yank.app is rejected")
    func missingBundleIsRejected() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()

        let error = #expect(throws: UpdateError.self) {
            try stage(fixture, runner: recorder.makeRunner())
        }

        guard case .missingBundle = error else {
            Issue.record("Expected a missing bundle, got \(String(describing: error))")
            return
        }
        #expect(recorder.invoked == ["ditto"], "Signature checks ran without a bundle")
    }

    @Test("A bundle carrying another identifier never reaches signature verification")
    func wrongBundleIdentifierIsRejected() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()

        let error = #expect(throws: UpdateError.self) {
            try stage(fixture, runner: recorder.makeRunner(extracting: ("com.example.impostor", "1.2.0")))
        }

        guard case .bundleIdentifierMismatch = error else {
            Issue.record("Expected an identifier mismatch, got \(String(describing: error))")
            return
        }
        #expect(recorder.invoked == ["ditto"])
    }

    @Test("A bundle whose version differs from the offered release is rejected")
    func versionMismatchIsRejected() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()

        let error = #expect(throws: UpdateError.self) {
            try stage(
                fixture,
                expectedVersion: "1.2.0",
                runner: recorder.makeRunner(extracting: ("com.thepatientzero.yank", "9.9.9"))
            )
        }

        guard case .versionMismatch = error else {
            Issue.record("Expected a version mismatch, got \(String(describing: error))")
            return
        }
        #expect(recorder.invoked == ["ditto"])
    }

    @Test("A failed signature check stops the install before Gatekeeper")
    func codesignFailureStopsTheInstall() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()

        #expect(throws: UpdateError.self) {
            try stage(
                fixture,
                runner: recorder.makeRunner(
                    extracting: ("com.thepatientzero.yank", "1.2.0"),
                    failing: "codesign"
                )
            )
        }

        #expect(recorder.invoked == ["ditto", "codesign"], "spctl ran after codesign failed")
    }

    @Test("A Gatekeeper rejection stops the install")
    func gatekeeperFailureStopsTheInstall() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()

        #expect(throws: UpdateError.self) {
            try stage(
                fixture,
                runner: recorder.makeRunner(
                    extracting: ("com.thepatientzero.yank", "1.2.0"),
                    failing: "spctl"
                )
            )
        }

        #expect(recorder.invoked == ["ditto", "codesign", "spctl"])
    }

    @Test("A matching, correctly identified, verified bundle stages inside the given root")
    func matchingBundleStages() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()

        let staged = try stage(
            fixture,
            runner: recorder.makeRunner(extracting: ("com.thepatientzero.yank", "1.2.0"))
        )

        #expect(recorder.invoked == ["ditto", "codesign", "spctl"])
        #expect(staged.version == "1.2.0")
        #expect(staged.tag == "v1.2.0")
        #expect(staged.targetAppPath == fixture.target.path)
        #expect(staged.stagedAppPath.hasSuffix("/Yank.app"))
        #expect(staged.stagedAppPath.hasPrefix(fixture.stagingRoot.path + "/"))
        #expect(FileManager.default.fileExists(atPath: staged.stagedAppPath))
    }

    // MARK: - Install target

    @Test("An install target that is not a Yank app bundle is refused before any command runs")
    func unsafeInstallTargetIsRefused() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()
        let staged = StagedUpdate(
            version: "1.2.0",
            tag: "v1.2.0",
            stagedAppPath: fixture.root.appendingPathComponent("Yank.app").path,
            targetAppPath: "/Applications/Finder.app",
            stagedAt: Date(),
            releaseNotes: nil,
            releaseURL: nil
        )

        let error = #expect(throws: UpdateError.self) {
            try UpdateInstaller.launchStagedInstall(staged, runner: recorder.makeRunner())
        }

        guard case .unsafeInstallTarget = error else {
            Issue.record("Expected an unsafe install target, got \(String(describing: error))")
            return
        }
        #expect(recorder.invoked.isEmpty)
    }

    @Test("A staged bundle that has disappeared is refused before any command runs")
    func missingStagedBundleIsRefused() throws {
        let fixture = try makeFixture()
        defer { remove(fixture) }
        let recorder = RecordingRunner()
        let staged = StagedUpdate(
            version: "1.2.0",
            tag: "v1.2.0",
            stagedAppPath: fixture.root.appendingPathComponent("gone/Yank.app").path,
            targetAppPath: fixture.target.path,
            stagedAt: Date(),
            releaseNotes: nil,
            releaseURL: nil
        )

        let error = #expect(throws: UpdateError.self) {
            try UpdateInstaller.launchStagedInstall(staged, runner: recorder.makeRunner())
        }

        guard case .missingBundle = error else {
            Issue.record("Expected a missing bundle, got \(String(describing: error))")
            return
        }
        #expect(recorder.invoked.isEmpty)
    }
}
