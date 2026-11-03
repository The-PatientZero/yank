import Foundation
import CloudKit
#if SWIFT_PACKAGE
import YankCore
#endif

/// Turns a thrown sync error into a `SyncFailure` the apps can show in plain words.
enum CloudKitSyncFailureClassifier {
    /// Kinds in the order a person can most usefully act on them. When a batch fails for several
    /// reasons, the earliest kind here wins.
    private static let actionOrder: [SyncFailureKind] = [
        .storageFull, .signedOut, .accountRestricted, .accountUnavailable, .offline, .busy
    ]

    private static let offlineURLErrorCodes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue,
        URLError.networkConnectionLost.rawValue,
        URLError.dataNotAllowed.rawValue
    ]

    static func classify(_ error: any Error) -> SyncFailure {
        if let syncError = error as? CloudKitSyncError {
            return syncError.failure
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, offlineURLErrorCodes.contains(nsError.code) {
            return SyncFailure(kind: .offline)
        }
        guard let code = CloudKitSyncService.cloudKitErrorCode(of: error) else {
            return SyncFailure(kind: .other)
        }
        if code == .partialFailure {
            return classify(itemErrors: partialErrors(of: error)) ?? SyncFailure(kind: .other, code: code.rawValue)
        }
        return SyncFailure(kind: kind(of: code), code: code.rawValue)
    }

    /// The most actionable failure among per-record errors. `batchRequestFailed` only says the
    /// record was dropped because another one in the batch failed, so it is ignored. Nil when
    /// every error was that kind of echo.
    static func classify(itemErrors: [any Error]) -> SyncFailure? {
        let failures = itemErrors
            .filter { CloudKitSyncService.cloudKitErrorCode(of: $0) != .batchRequestFailed }
            .map(classify)
        for kind in actionOrder {
            if let match = failures.first(where: { $0.kind == kind }) { return match }
        }
        return failures.first
    }

    private static func partialErrors(of error: any Error) -> [any Error] {
        let itemErrors: [AnyHashable: any Error]?
        if let cloudKitError = error as? CKError {
            itemErrors = cloudKitError.partialErrorsByItemID
        } else {
            itemErrors = (error as NSError).userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error]
        }
        return itemErrors.map { Array($0.values) } ?? []
    }

    private static func kind(of code: CKError.Code) -> SyncFailureKind {
        switch code {
        case .networkUnavailable, .networkFailure:
            .offline
        case .notAuthenticated:
            .signedOut
        case .managedAccountRestricted:
            .accountRestricted
        case .accountTemporarilyUnavailable:
            .accountUnavailable
        case .quotaExceeded:
            .storageFull
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            .busy
        default:
            .other
        }
    }
}
