import Foundation

/// A faithful snapshot of every representation on a pasteboard item. Most clips flatten to a
/// single `.text`/`.image`, but rich copies (RTF/HTML, PDF) carry several representations at
/// once; archiving all of them lets paste replay the exact bytes instead of a lossy fallback.
public struct PasteboardArchive: Codable, Equatable, Sendable {
    public struct Representation: Codable, Equatable, Sendable {
        /// The pasteboard type's UTI, e.g. `public.rtf`, `com.adobe.pdf`.
        public let uti: String
        public let data: Data

        public init(uti: String, data: Data) {
            self.uti = uti
            self.data = data
        }
    }

    public let representations: [Representation]

    public init(representations: [Representation]) {
        self.representations = representations
    }

    public var isEmpty: Bool { representations.isEmpty }

    public var totalBytes: Int { representations.reduce(0) { $0 + $1.data.count } }

    /// UTIs that carry fidelity a plain-text / raster fallback would lose. The presence
    /// of any of these is what makes a copy worth archiving in full.
    public static let richUTIs: Set<String> = [
        "public.rtf",
        "public.rtfd",
        "com.apple.flat-rtfd",
        "public.html",
        "com.adobe.pdf"
    ]

    /// Whether a copy with these representation UTIs is worth a full archive.
    public static func isRich(utis: [String]) -> Bool {
        utis.contains { richUTIs.contains($0) }
    }
}
