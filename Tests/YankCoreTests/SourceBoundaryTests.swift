import Foundation
import Testing

@Suite("Source Boundaries")
struct SourceBoundaryTests {
    @Test("YankCore stays independent of platform UI and CloudKit")
    func coreImportsStayPlatformFree() throws {
        let violations = try imports(in: "Sources/YankCore").filter { _, imported in
            ["AppKit", "CloudKit", "SwiftUI", "UIKit"].contains(imported)
        }

        #expect(violations.isEmpty)
    }

    @Test("CloudKit sync only depends on core and system transport modules")
    func cloudKitSyncImportsStayNarrow() throws {
        let allowed = Set(["CloudKit", "Foundation", "Security", "os", "YankCore"])
        let violations = try imports(in: "Sources/YankCloudKitSync").filter { _, imported in
            !allowed.contains(imported)
        }

        #expect(violations.isEmpty)
    }

    private func imports(in relativePath: String) throws -> [(file: URL, imported: String)] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(relativePath, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        return try files.flatMap { file -> [(URL, String)] in
            let source = try String(contentsOf: file, encoding: .utf8)
            return source.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { return nil }
                return (file, String(trimmed.dropFirst("import ".count).split(separator: " ").first ?? ""))
            }
        }
    }
}
