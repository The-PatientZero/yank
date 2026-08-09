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
