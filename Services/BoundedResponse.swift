import Foundation

/// Reads a response body into memory under an explicit ceiling.
///
/// `URLSession.data` buffers whatever the server sends, so a compromised or misbehaving host
/// could make the updater allocate without limit. Streaming the body and stopping at the
/// declared limit bounds that, and a lied-about `Content-Length` cannot get past it because the
/// running total is what decides. Only the small metadata bodies use this — the app payload
/// streams to disk and is bounded by its checksum instead.
enum BoundedResponse {
    /// Chunk the byte stream rather than appending one byte at a time: `AsyncBytes` yields
    /// individual bytes, and a per-byte `Data.append` over a multi-kilobyte body is needlessly
    /// slow for no added safety.
    private static let chunkSize = 16 * 1_024

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
}
