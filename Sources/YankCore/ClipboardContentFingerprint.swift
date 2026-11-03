import CryptoKit
import Foundation

/// Ephemeral fingerprint for consecutive-capture suppression. It is intentionally
/// full-content rather than prefix-based so large clips that share a header cannot
/// collapse into one history entry.
struct ClipboardContentFingerprint: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case fileList
        case image
        case text
    }

    let kind: Kind
    let byteCount: Int
    private let sha256: [UInt8]

    static func text(_ text: String) -> ClipboardContentFingerprint {
        bytes(Data(text.utf8), kind: .text)
    }

    static func fileList(_ summary: String) -> ClipboardContentFingerprint {
        bytes(Data(summary.utf8), kind: .fileList)
    }

    static func image(_ data: Data) -> ClipboardContentFingerprint {
        bytes(data, kind: .image)
    }

    private static func bytes(_ data: Data, kind: Kind) -> ClipboardContentFingerprint {
        ClipboardContentFingerprint(
            kind: kind,
            byteCount: data.count,
            sha256: Array(SHA256.hash(data: data))
        )
    }
}

/// Decides whether a pasteboard capture is a re-assert of the last one the watcher applied.
///
/// Some apps rewrite the pasteboard with byte-identical content without a user copy (activation
/// rewrites, lazy-promise re-declares). Plain text is dropped only when it comes from the same
/// source app within `reassertSuppressionWindow`; two deliberate copies further apart are two copy
/// events. Kinds that durable deduplication cannot collapse (rich, image, file list, file-backed
/// or truncated text) keep suppressing any consecutive repeat. A change of the store's reset
/// revision (delete, clear history, unsaved capture) always clears the suppression.
struct ClipboardRepeatGuard: Sendable {
    /// The watcher polls every 0.5 s, so a re-assert lands within a few polls of the app's own
    /// write, while a person copying the same text twice takes longer than this.
    static let reassertSuppressionWindow: TimeInterval = 3

    private struct Applied: Sendable {
        let fingerprint: ClipboardContentFingerprint
        let sourceApp: String?
        let observedAt: Date
        let resetRevision: Int
    }

    private var lastApplied: Applied?

    func isRepeat(
        _ fingerprint: ClipboardContentFingerprint,
        sourceApp: String?,
        observedAt: Date,
        resetRevision: Int,
        usesWindow: Bool
    ) -> Bool {
        guard let last = lastApplied,
              last.fingerprint == fingerprint,
              last.resetRevision == resetRevision else {
            return false
        }
        guard usesWindow else { return true }
        let elapsed = observedAt.timeIntervalSince(last.observedAt)
        return last.sourceApp == sourceApp
            && (0..<Self.reassertSuppressionWindow).contains(elapsed)
    }

    /// Call only after the capture was saved. `resetRevision` is the store's value from before
    /// the save started, so a delete that lands during the save still clears the suppression.
    mutating func recordApplied(
        _ fingerprint: ClipboardContentFingerprint,
        sourceApp: String?,
        observedAt: Date,
        resetRevision: Int
    ) {
        lastApplied = Applied(
            fingerprint: fingerprint,
            sourceApp: sourceApp,
            observedAt: observedAt,
            resetRevision: resetRevision
        )
    }
}
