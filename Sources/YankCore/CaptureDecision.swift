import Foundation

/// The one answer to "is this capture new?" for durable history, shared by the macOS and iOS
/// stores. A capture refreshes the newest history item with the same `TextCaptureIdentity`,
/// otherwise it is inserted. Items waiting out their undo window are excluded from matching so
/// a fresh copy never collapses into a clip that is about to be deleted.
enum DuplicateCaptureDecision: Equatable, Sendable {
    case insert
    case refresh(existingID: UUID)

    static func decide(
        for candidate: ClipboardItem,
        in history: [ClipboardItem],
        excluding excludedIDs: Set<UUID> = []
    ) -> DuplicateCaptureDecision {
        let newestMatch = history
            .filter { !excludedIDs.contains($0.id) && TextCaptureIdentity.matches($0, candidate) }
            .max { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard let newestMatch else { return .insert }
        return .refresh(existingID: newestMatch.id)
    }
}
