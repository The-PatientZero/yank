import Darwin
import Foundation
import Testing
@testable import Yank

@Suite("CloudKit backfill command")
struct CloudKitBackfillCommandTests {
    private static let processTimeout = DispatchTimeInterval.seconds(10)
    private static let terminationGrace = DispatchTimeInterval.seconds(2)

    @Test("Dry run and converged apply are the only successful result mappings")
    func successMapping() {
        let missingPreview = result(remainingMissing: 2)
        let converged = result(remainingMissing: 0)

        #expect(
            CloudKitBackfillCommandOutcome.completed(
                dryRun: true,
                result: missingPreview
            ).exitStatus == EXIT_SUCCESS
        )
        #expect(
            CloudKitBackfillCommandOutcome.completed(
                dryRun: false,
                result: converged
            ).exitStatus == EXIT_SUCCESS
        )
        #expect(
            CloudKitBackfillCommandOutcome.completed(
                dryRun: false,
                result: missingPreview
            ).exitStatus == EXIT_FAILURE
        )
    }

    @Test("Every prerequisite and operational failure is nonzero and one line")
    func failureMapping() {
        enum Failure: LocalizedError {
            case partial

            var errorDescription: String? {
                "partial save\nrequires retry"
            }
        }

        let outcomes = [
            CloudKitBackfillCommandOutcome.prerequisiteFailure("sync-disabled"),
            CloudKitBackfillCommandOutcome.prerequisiteFailure("container-not-provisioned"),
            CloudKitBackfillCommandOutcome.failed(Failure.partial)
        ]

        #expect(outcomes.allSatisfy { $0.exitStatus == EXIT_FAILURE })
        #expect(outcomes.allSatisfy { !$0.marker.contains("\n") })
        #expect(outcomes.allSatisfy { $0.marker.hasPrefix("YANK_CLOUD_BACKFILL_FAILURE") })
    }

    @Test("The built executable returns nonzero for a safe disabled dry run")
    func executableReturnsFailureStatus() throws {
        let executableURL = try #require(Bundle.main.executableURL)
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankBackfillCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: isolatedHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--cloudkit-backfill-dry-run",
            "-syncEnabled",
            "NO"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = isolatedHome.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = Pipe()

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        guard completion.wait(timeout: .now() + Self.processTimeout) == .success else {
            process.terminate()
            _ = completion.wait(timeout: .now() + Self.terminationGrace)
            throw CloudKitBackfillCommandTestError.processTimedOut
        }
        let marker = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        #expect(process.terminationStatus == EXIT_FAILURE)
        #expect(marker.contains("YANK_CLOUD_BACKFILL_FAILURE reason=sync-disabled"))
    }

    private func result(remainingMissing: Int) -> CloudKitBackfillResult {
        CloudKitBackfillResult(
            localRecordCount: 3,
            presentRecordCountBefore: 1,
            missingRecordCountBefore: 2,
            uploadedRecordCount: remainingMissing == 0 ? 2 : 1,
            presentRecordCountAfter: 3 - remainingMissing,
            remainingMissingRecordCount: remainingMissing
        )
    }
}

private enum CloudKitBackfillCommandTestError: Error {
    case processTimedOut
}
