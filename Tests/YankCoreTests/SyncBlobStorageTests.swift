import Foundation
import Testing
@testable import YankCore

@Suite struct SyncBlobStorageTests {
    @Test func writeThenReadRoundTripsBlobData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yank-sync-blob-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.txt")
        let data = Data("synced blob".utf8)

        try await SyncBlobStorage.write(data, to: url)
        let restored = try await SyncBlobStorage.read(from: url)

        #expect(restored == data)
    }

    @Test func readMissingBlobSurfacesError() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).bin")

        await expectCocoaError(
            CocoaError.Code.fileReadNoSuchFile.rawValue,
            "missing synced blob should surface a no-such-file error"
        ) {
            _ = try await SyncBlobStorage.read(from: url)
        }
    }

    @Test func writeToDirectoryURLSurfacesError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yank-sync-blob-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await expectCocoaError(
            CocoaError.Code.fileWriteUnknown.rawValue,
            "writing blob data to a directory URL should surface a file-write error"
        ) {
            try await SyncBlobStorage.write(Data("not a file".utf8), to: directory)
        }
    }

    @Test func writeRejectsBlobsOverTheByteBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yank-sync-blob-write-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.txt")

        do {
            try await SyncBlobStorage.write(Data("oversized".utf8), to: url, maxBytes: 4)
            Issue.record("Expected oversized synced blob write to throw")
        } catch let error as SyncBlobStorage.Error {
            #expect(error == .oversizedBlob(actualBytes: 9, maxBytes: 4))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func writeAppliesRequestedPrivateFileAttributes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yank-sync-blob-attributes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.txt")

        try await SyncBlobStorage.write(
            Data("private".utf8),
            to: url,
            writeOptions: .atomic,
            filePermissions: 0o600,
            fileProtection: .complete
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        expectProtection(attributes[.protectionKey] as? FileProtectionType, matches: .complete)
    }

    private func expectCocoaError(
        _ expectedCode: Int,
        _ message: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected Cocoa error: \(message)")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSCocoaErrorDomain, Comment(rawValue: "Unexpected error domain for: \(message)"))
            #expect(nsError.code == expectedCode, Comment(rawValue: "Unexpected Cocoa error code for: \(message)"))
        }
    }

    private func expectProtection(_ actual: FileProtectionType?, matches requested: FileProtectionType) {
        if actual == requested { return }
        #if os(macOS)
        if actual == nil { return }
        if requested == .complete, actual == .completeUntilFirstUserAuthentication { return }
        #endif
        #expect(actual == requested)
    }
}
