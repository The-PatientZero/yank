import Foundation
import Testing

@Suite("App Store Connect release tool")
struct AppStoreConnectReleaseToolTests {
    @Test("Empty build history starts at one")
    func emptyBuildHistoryStartsAtOne() throws {
        let result = try runTool(
            arguments: ["next-build-from-json"],
            json: #"{"data":[]}"#
        )

        #expect(result.status == 0)
        #expect(result.standardOutput == "1")
        #expect(result.standardError.isEmpty)
    }

    @Test("Next build follows the largest numeric build")
    func nextBuildFollowsLargestNumericBuild() throws {
        let result = try runTool(
            arguments: ["next-build-from-json"],
            json: """
            {
              "data": [
                {"type":"builds","id":"a","attributes":{"version":"2"}},
                {"type":"builds","id":"b","attributes":{"version":"10"}},
                {"type":"builds","id":"c","attributes":{"version":"7"}}
              ]
            }
            """
        )

        #expect(result.status == 0)
        #expect(result.standardOutput == "11")
    }

    @Test(
        "Invalid build histories fail closed",
        arguments: [
            #"{"data":[{"type":"builds","id":"a","attributes":{"version":"1.2"}}]}"#,
            #"{"data":[{"type":"builds","id":"a","attributes":{"version":"1"}},{"type":"builds","id":"b","attributes":{"version":"1"}}]}"#,
            #"{"data":[{"type":"apps","id":"a","attributes":{"version":"1"}}]}"#,
            #"{"data":{}}"#,
            #"{"errors":[{"status":"500"}]}"#
        ]
    )
    func invalidBuildHistoriesFailClosed(json: String) throws {
        let result = try runTool(
            arguments: ["next-build-from-json"],
            json: json
        )

        #expect(result.status != 0)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("malformed"))
    }

    @Test("Build processing state is exact and typed")
    func buildProcessingStateIsExactAndTyped() throws {
        let processing = try runTool(
            arguments: ["build-state-from-json", "12"],
            json: prereleaseResponse(build: "12", id: "build-12", state: "PROCESSING")
        )
        let valid = try runTool(
            arguments: ["build-state-from-json", "12"],
            json: prereleaseResponse(build: "12", id: "build-12", state: "VALID")
        )
        let failed = try runTool(
            arguments: ["build-state-from-json", "12"],
            json: prereleaseResponse(build: "12", id: "build-12", state: "FAILED")
        )
        let missing = try runTool(
            arguments: ["build-state-from-json", "13"],
            json: prereleaseResponse(build: "12", id: "build-12", state: "VALID")
        )

        #expect(processing.standardOutput == "build-12 PROCESSING")
        #expect(valid.standardOutput == "build-12 VALID")
        #expect(failed.standardOutput == "build-12 FAILED")
        #expect(missing.standardOutput == "MISSING")
    }

    @Test("Ambiguous or unknown processing states fail closed")
    func invalidProcessingStatesFailClosed() throws {
        let ambiguous = try runTool(
            arguments: ["build-state-from-json", "12"],
            json: """
            {
              "data": [],
              "included": [
                {"type":"builds","id":"a","attributes":{"version":"12","processingState":"VALID"}},
                {"type":"builds","id":"b","attributes":{"version":"12","processingState":"VALID"}}
              ]
            }
            """
        )
        let unknown = try runTool(
            arguments: ["build-state-from-json", "12"],
            json: prereleaseResponse(build: "12", id: "build-12", state: "UNKNOWN")
        )

        #expect(ambiguous.status != 0)
        #expect(ambiguous.standardError.contains("multiple builds"))
        #expect(unknown.status != 0)
        #expect(unknown.standardError.contains("malformed prerelease response"))
    }

    @Test("Internal-group relationship verification is exact")
    func relationshipVerificationIsExact() throws {
        let json = """
        {
          "data": [
            {"type":"builds","id":"build-11"},
            {"type":"builds","id":"build-12"}
          ]
        }
        """
        let found = try runTool(
            arguments: ["relationship-has-build-from-json", "build-12"],
            json: json
        )
        let absent = try runTool(
            arguments: ["relationship-has-build-from-json", "build-13"],
            json: json
        )

        #expect(found.status == 0)
        #expect(absent.status != 0)
    }

    @Test("Generated API token has a valid ES256 signature")
    func generatedTokenHasValidSignature() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let keyFile = temporaryDirectory.appendingPathComponent("AuthKey_TEST.p8")
        let keyGeneration = try runProcess(
            executable: "/usr/bin/openssl",
            arguments: [
                "genpkey",
                "-algorithm", "EC",
                "-pkeyopt", "ec_paramgen_curve:P-256",
                "-out", keyFile.path
            ]
        )
        #expect(keyGeneration.status == 0)

        let validation = try runProcess(
            executable: "/bin/bash",
            arguments: [
                repositoryRoot
                    .appendingPathComponent("scripts/app_store_connect.sh")
                    .path,
                "validate-token"
            ],
            environment: [
                "ASC_KEY_PATH": keyFile.path,
                "ASC_KEY_ID": "TESTKEY123",
                "ASC_ISSUER_ID": "00000000-0000-0000-0000-000000000000"
            ]
        )

        #expect(validation.status == 0)
        #expect(validation.standardOutput == "Token signing validated.")
        #expect(validation.standardError.isEmpty)
    }

    @Test("Release scripts parse and archive validation fails closed")
    func releaseScriptsParseAndArchiveValidationFailsClosed() throws {
        for script in ["app_store_connect.sh", "validate_ios_archive.sh"] {
            let syntax = try runProcess(
                executable: "/bin/bash",
                arguments: [
                    "-n",
                    repositoryRoot.appendingPathComponent("scripts/\(script)").path
                ]
            )
            #expect(syntax.status == 0, "\(script): \(syntax.standardError)")
        }

        let appStoreConnectScript = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("scripts/app_store_connect.sh"),
            encoding: .utf8
        )
        #expect(
            appStoreConnectScript.contains(
                #"if assignment_exists "$group_id" "$build_id"; then"#
            )
        )

        let missingArchive = try runProcess(
            executable: "/bin/bash",
            arguments: [
                repositoryRoot
                    .appendingPathComponent("scripts/validate_ios_archive.sh")
                    .path,
                "/tmp/yank-missing-release-archive",
                "1.0.3",
                "2",
                "ABCDE12345"
            ]
        )
        #expect(missingArchive.status != 0)
        #expect(missingArchive.standardOutput.isEmpty)
        #expect(missingArchive.standardError.contains("archive does not exist"))
    }

    private func prereleaseResponse(
        build: String,
        id: String,
        state: String
    ) -> String {
        """
        {
          "data": [],
          "included": [
            {
              "type": "builds",
              "id": "\(id)",
              "attributes": {
                "version": "\(build)",
                "processingState": "\(state)"
              }
            }
          ]
        }
        """
    }

    private func runTool(
        arguments: [String],
        json: String
    ) throws -> ToolResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let responseFile = temporaryDirectory.appendingPathComponent("response.json")
        try Data(json.utf8).write(to: responseFile, options: .atomic)

        return try runProcess(
            executable: "/bin/bash",
            arguments: [
                repositoryRoot
                    .appendingPathComponent("scripts/app_store_connect.sh")
                    .path
            ]
                + Array(arguments.prefix(1))
                + [responseFile.path]
                + Array(arguments.dropFirst())
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment additions: [String: String] = [:]
    ) throws -> ToolResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(additions) {
            _, addition in addition
        }
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ToolResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private struct ToolResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }
}
