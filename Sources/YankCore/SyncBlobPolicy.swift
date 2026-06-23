import Foundation

/// Kinds of blob files that can be exchanged through sync.
public enum SyncBlobKind: Hashable, Sendable {
    case image
    case text
    case rich

    /// Required filename extension for this blob kind.
    public var allowedExtension: String {
        switch self {
        case .image: "png"
        case .text: "txt"
        case .rich: "plist"
        }
    }

    /// Maximum accepted byte size for this blob kind.
    public var maximumBytes: Int {
        switch self {
        case .image:
            32 * 1024 * 1024
        case .text, .rich:
            16 * 1024 * 1024
        }
    }
}

/// Validation and containment rules for synced blob filenames and file URLs.
public enum SyncBlobPolicy {
    /// Conservative maximum for any synced blob.
    public static let maxSyncedBlobBytes = 32 * 1024 * 1024

    /// Select the synced blob kind for primary clip content.
    public static func kind(isImage: Bool) -> SyncBlobKind {
        isImage ? .image : .text
    }

    /// Return a canonical filename only if it is a bare UUID filename with the expected extension.
    public static func validatedFilename(_ filename: String, kind: SyncBlobKind) -> String? {
        guard filename == filename.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains(":"),
              filename != ".",
              filename != ".." else { return nil }

        let url = URL(fileURLWithPath: filename)
        guard url.lastPathComponent == filename else { return nil }
        guard url.pathExtension.lowercased() == kind.allowedExtension else { return nil }

        let stem = String(filename.dropLast(kind.allowedExtension.count + 1))
        guard UUID(uuidString: stem) != nil else { return nil }
        return filename
    }

    /// Build a URL under `directory`, rejecting filenames that would escape containment.
    public static func containedURL(directory: URL, filename: String, kind: SyncBlobKind) -> URL? {
        guard let filename = validatedFilename(filename, kind: kind) else { return nil }

        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directory
            .appendingPathComponent(filename, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(basePath) else { return nil }
        return candidate
    }

    /// Canonical text blob filename, or nil if absent or invalid.
    public static func canonicalTextFilename(_ filename: String?) -> String? {
        filename.flatMap { validatedFilename($0, kind: .text) }
    }

    /// Canonical image blob filename, or nil if absent or invalid.
    public static func canonicalImageFilename(_ filename: String?) -> String? {
        filename.flatMap { validatedFilename($0, kind: .image) }
    }

    /// Canonical rich-archive blob filename, or nil if absent or invalid.
    public static func canonicalRichFilename(_ filename: String?) -> String? {
        filename.flatMap { validatedFilename($0, kind: .rich) }
    }
}

/// A validated reference to a synced blob file.
public struct SyncBlobReference: Hashable, Sendable {
    /// Canonical bare filename.
    public let filename: String
    /// Blob kind that determines extension and byte limit.
    public let kind: SyncBlobKind

    /// Creates a reference only when the filename is valid for `kind`.
    public init?(filename: String?, kind: SyncBlobKind) {
        guard let filename = filename.flatMap({ SyncBlobPolicy.validatedFilename($0, kind: kind) }) else {
            return nil
        }
        self.filename = filename
        self.kind = kind
    }

    /// Maximum accepted byte size for this referenced blob.
    public var maximumBytes: Int { kind.maximumBytes }

    /// Contained file URL for this reference under `directory`.
    public func containedURL(in directory: URL) -> URL? {
        SyncBlobPolicy.containedURL(directory: directory, filename: filename, kind: kind)
    }
}
