import Foundation

enum HistorySnapshotTransactionPhase: Sendable {
    case transactionStaged
    case historyReplaced
    case tombstonesReplaced
}

enum HistorySnapshotTransactionError: LocalizedError {
    case tombstoneEncodingFailed
    case invalidEnvelope
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .tombstoneEncodingFailed:
            "The deletion log could not be encoded."
        case .invalidEnvelope:
            "The pending history transaction is invalid."
        case .unsupportedVersion(let version):
            "The pending history transaction uses unsupported version \(version)."
        }
    }
}

/// Write-ahead checkpoint for the two legacy canonical files.
///
/// The envelope is additive and temporary: older Yank versions continue to read the same
/// `history.json` and `tombstones.json` files, while a newer loader can finish an interrupted
/// replacement of that pair before decoding either canonical file.
enum HistorySnapshotTransaction {
    private struct Envelope: Codable {
        let version: Int
        let transactionID: UUID
        let historyData: Data
        let tombstonesData: Data
        let writeOptionsRawValue: UInt
        let filePermissions: Int?
        let fileProtectionRawValue: String?
    }

    private struct ValidatedEnvelope {
        let historyData: Data
        let tombstonesData: Data
        let writeOptions: Data.WritingOptions
        let filePermissions: Int?
        let fileProtection: FileProtectionType?
    }

    static let currentVersion = 1

    static func transactionURL(for historyURL: URL) -> URL {
        historyURL.appendingPathExtension("transaction")
    }

    static func makeEnvelopeData(
        items: [ClipboardItem],
        tombstones: [UUID: Date],
        writeOptions: Data.WritingOptions,
        filePermissions: Int?,
        fileProtection: FileProtectionType?
    ) throws -> Data {
        guard let tombstonesData = TombstoneCodec.encode(tombstones) else {
            throw HistorySnapshotTransactionError.tombstoneEncodingFailed
        }
        let envelope = Envelope(
            version: currentVersion,
            transactionID: UUID(),
            historyData: try JSONEncoder().encode(items),
            tombstonesData: tombstonesData,
            writeOptionsRawValue: writeOptions.union(.atomic).rawValue,
            filePermissions: filePermissions,
            fileProtectionRawValue: fileProtection?.rawValue
        )
        return try JSONEncoder().encode(envelope)
    }

    static func stage(
        _ envelopeData: Data,
        at transactionURL: URL,
        writeOptions: Data.WritingOptions,
        filePermissions: Int?,
        fileProtection: FileProtectionType?
    ) throws {
        try envelopeData.write(to: transactionURL, options: writeOptions.union(.atomic))
        try PrivateFileAttributes.apply(
            to: transactionURL,
            permissions: filePermissions,
            protection: fileProtection
        )
    }

    static func replayIfPresent(
        historyURL: URL,
        tombstonesURL: URL,
        afterCanonicalWrite: (@Sendable (HistorySnapshotTransactionPhase) throws -> Void)? = nil
    ) throws {
        let transactionURL = transactionURL(for: historyURL)
        guard FileManager.default.fileExists(atPath: transactionURL.path) else { return }

        let envelopeData = try Data(contentsOf: transactionURL)
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: envelopeData)
        } catch {
            throw HistorySnapshotTransactionError.invalidEnvelope
        }
        let validated = try validate(envelope)

        // A writer may have been interrupted after the atomic envelope write but before its
        // attribute step completed. Re-establish the declared privacy attributes before
        // allowing recovery to replace either canonical file.
        try PrivateFileAttributes.apply(
            to: transactionURL,
            permissions: validated.filePermissions,
            protection: validated.fileProtection
        )
        try writeCanonical(
            validated.historyData,
            to: historyURL,
            writeOptions: validated.writeOptions,
            filePermissions: validated.filePermissions,
            fileProtection: validated.fileProtection
        )
        try afterCanonicalWrite?(.historyReplaced)
        try writeCanonical(
            validated.tombstonesData,
            to: tombstonesURL,
            writeOptions: validated.writeOptions,
            filePermissions: validated.filePermissions,
            fileProtection: validated.fileProtection
        )
        try afterCanonicalWrite?(.tombstonesReplaced)
        try FileManager.default.removeItem(at: transactionURL)
    }

    static func writeCanonical(
        _ data: Data,
        to url: URL,
        writeOptions: Data.WritingOptions,
        filePermissions: Int?,
        fileProtection: FileProtectionType?
    ) throws {
        try data.write(to: url, options: writeOptions.union(.atomic))
        try PrivateFileAttributes.apply(
            to: url,
            permissions: filePermissions,
            protection: fileProtection
        )
    }

    private static func validate(_ envelope: Envelope) throws -> ValidatedEnvelope {
        guard envelope.version == currentVersion else {
            throw HistorySnapshotTransactionError.unsupportedVersion(envelope.version)
        }

        let writeOptions = Data.WritingOptions(rawValue: envelope.writeOptionsRawValue)
        let supportedOptions: Data.WritingOptions = [
            .atomic,
            .completeFileProtection,
            .completeFileProtectionUnlessOpen,
            .completeFileProtectionUntilFirstUserAuthentication,
            .noFileProtection
        ]
        guard writeOptions.contains(.atomic),
              writeOptions.isSubset(of: supportedOptions),
              permissionsArePrivate(envelope.filePermissions),
              protectionIsSupported(envelope.fileProtectionRawValue),
              (try? JSONDecoder().decode([ClipboardItem].self, from: envelope.historyData)) != nil,
              (try? TombstoneCodec.decodeStrict(envelope.tombstonesData)) != nil else {
            throw HistorySnapshotTransactionError.invalidEnvelope
        }

        return ValidatedEnvelope(
            historyData: envelope.historyData,
            tombstonesData: envelope.tombstonesData,
            writeOptions: writeOptions,
            filePermissions: envelope.filePermissions,
            fileProtection: envelope.fileProtectionRawValue.map(FileProtectionType.init(rawValue:))
        )
    }

    private static func permissionsArePrivate(_ permissions: Int?) -> Bool {
        guard let permissions else { return true }
        return (0...0o777).contains(permissions) && permissions & 0o077 == 0
    }

    private static func protectionIsSupported(_ rawValue: String?) -> Bool {
        guard let rawValue else { return true }
        return Set([
            FileProtectionType.complete.rawValue,
            FileProtectionType.completeUnlessOpen.rawValue,
            FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
            FileProtectionType.none.rawValue
        ]).contains(rawValue)
    }
}
