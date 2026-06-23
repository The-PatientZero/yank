import Foundation

/// Off-main blob file I/O for CloudKit assets. Stores decide the destination URL;
/// this helper keeps the blocking read/write work out of UI actors and makes failures
/// throw instead of disappearing behind `try?`.
public enum SyncBlobStorage {
    private static let readChunkSize = 64 * 1024

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case notRegularFile
        case unsafeFilename
        case oversizedBlob(actualBytes: Int, maxBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .notRegularFile:
                "Synced blob is not a regular file."
            case .unsafeFilename:
                "Synced blob filename is not allowed."
            case .oversizedBlob(let actualBytes, let maxBytes):
                "Synced blob is \(actualBytes) bytes; maximum is \(maxBytes) bytes."
            }
        }
    }

    public static func read(from url: URL, maxBytes: Int = SyncBlobPolicy.maxSyncedBlobBytes) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard maxBytes >= 0 else {
                throw Error.oversizedBlob(actualBytes: 0, maxBytes: maxBytes)
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == false {
                throw Error.notRegularFile
            }
            if let size = values.fileSize, size > maxBytes {
                throw Error.oversizedBlob(actualBytes: size, maxBytes: maxBytes)
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var data = Data()
            data.reserveCapacity(min(maxBytes, readChunkSize))
            while true {
                let remainingBudget = maxBytes - data.count
                let chunkSize = min(readChunkSize, remainingBudget + 1)
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return data
                }
                let nextCount = data.count + chunk.count
                guard nextCount <= maxBytes else {
                    throw Error.oversizedBlob(actualBytes: nextCount, maxBytes: maxBytes)
                }
                data.append(chunk)
            }
        }.value
    }

    public static func write(
        _ data: Data,
        to url: URL,
        maxBytes: Int? = nil,
        writeOptions: Data.WritingOptions = .atomic,
        filePermissions: Int? = nil,
        fileProtection: FileProtectionType? = nil
    ) async throws {
        try await Task.detached(priority: .utility) {
            if let maxBytes, data.count > maxBytes {
                throw Error.oversizedBlob(actualBytes: data.count, maxBytes: maxBytes)
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: writeOptions)
            try PrivateFileAttributes.apply(
                to: url,
                permissions: filePermissions,
                protection: fileProtection
            )
        }.value
    }
}
