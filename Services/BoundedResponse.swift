import Foundation

/// Reads a response body under an explicit ceiling: streams and stops at `maximumBytes` so a
/// lied `Content-Length` can't bypass it (`URLSession.data` buffers unbounded). `load` keeps
/// small metadata bodies in memory; `download` streams the app payload to a temporary file.
enum BoundedResponse {
    /// Chunk the byte stream rather than appending one byte at a time: `AsyncBytes` yields
    /// individual bytes, and a per-byte `Data.append` over a multi-kilobyte body is needlessly
    /// slow for no added safety.
    private static let chunkSize = 16 * 1_024
    /// Owner read and write only, for the downloaded archive.
    private static let privateFileMode = 0o600

    static func load(
        _ request: URLRequest,
        what: String,
        maximumBytes: Int,
        session: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)

        // An honest oversized body is rejected before a single byte is buffered.
        if response.expectedContentLength > Int64(maximumBytes) {
            throw UpdateError.responseTooLarge(what: what, limitBytes: maximumBytes)
        }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, chunkSize))
        var chunk = [UInt8]()
        chunk.reserveCapacity(chunkSize)

        for try await byte in stream {
            chunk.append(byte)
            if chunk.count == chunkSize {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if data.count > maximumBytes {
                    throw UpdateError.responseTooLarge(what: what, limitBytes: maximumBytes)
                }
            }
        }
        data.append(contentsOf: chunk)
        guard data.count <= maximumBytes else {
            throw UpdateError.responseTooLarge(what: what, limitBytes: maximumBytes)
        }

        return (data, response)
    }

    /// Streams a response body to a new private temporary file under an explicit ceiling and
    /// returns that file's URL. `validateResponse` runs as soon as the headers arrive, before any
    /// data is written. The file is deleted on every failure and cancellation, so a caller only
    /// owns a file when this returns normally.
    static func download(
        _ request: URLRequest,
        what: String,
        maximumBytes: Int,
        validateResponse: @Sendable (URLResponse) throws -> Void,
        session: URLSession = .shared
    ) async throws -> (URL, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        try validateResponse(response)

        // An honest oversized body is rejected before a file is created.
        if response.expectedContentLength > Int64(maximumBytes) {
            throw UpdateError.responseTooLarge(what: what, limitBytes: maximumBytes)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yank-download-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: privateFileMode]
        ) else {
            throw UpdateError.underlying(operation: what, message: "could not create a temporary file")
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            do {
                try await write(stream, to: handle, what: what, maximumBytes: maximumBytes)
            } catch {
                // Close before the file is deleted; the stream error is the one to report.
                try? handle.close()
                throw error
            }
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        return (fileURL, response)
    }

    private static func write(
        _ stream: URLSession.AsyncBytes,
        to handle: FileHandle,
        what: String,
        maximumBytes: Int
    ) async throws {
        var written = 0
        var chunk = [UInt8]()
        chunk.reserveCapacity(chunkSize)

        for try await byte in stream {
            chunk.append(byte)
            if chunk.count == chunkSize {
                written += chunk.count
                guard written <= maximumBytes else {
                    throw UpdateError.responseTooLarge(what: what, limitBytes: maximumBytes)
                }
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        written += chunk.count
        guard written <= maximumBytes else {
            throw UpdateError.responseTooLarge(what: what, limitBytes: maximumBytes)
        }
        try handle.write(contentsOf: chunk)
    }
}
