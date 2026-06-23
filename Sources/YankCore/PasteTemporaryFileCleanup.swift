import Foundation

struct PasteTemporaryFileCleanup {
    struct Plan: Equatable {
        let directories: Set<URL>
        let delay: TimeInterval
    }

    static func directories(containing fileURLs: [URL]) -> Set<URL> {
        Set(fileURLs.map { $0.deletingLastPathComponent() })
    }

    static func planAfterPasteboardWrite(
        fileURLs: [URL],
        writeSucceeded: Bool,
        delay: TimeInterval
    ) -> Plan? {
        guard writeSucceeded else { return nil }
        let directories = directories(containing: fileURLs)
        guard !directories.isEmpty else { return nil }
        return Plan(directories: directories, delay: delay)
    }
}
