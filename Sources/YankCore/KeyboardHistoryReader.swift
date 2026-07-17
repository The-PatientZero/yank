import Foundation

/// Read-only keyboard view assembled exclusively from the host's bounded projection.
/// Pending share captures can contain large payloads and belong to the host import path;
/// the memory-constrained keyboard never scans or decodes that queue.
struct KeyboardHistoryReader: Sendable {
    let projectionURL: URL

    func load() throws -> [ClipboardItem] {
        guard FileManager.default.fileExists(atPath: projectionURL.path) else { return [] }
        return try KeyboardHistoryProjection.load(from: projectionURL).items
    }
}
