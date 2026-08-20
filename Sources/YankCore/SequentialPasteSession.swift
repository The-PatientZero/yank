import Foundation

/// Process-local FIFO state for a text paste sequence. Occurrences are deliberately independent
/// from persisted clipboard items — two copy events with identical text remain two entries. The
/// caller owns pasteboard observation and paste dispatch, then resolves each request's outcome.
struct SequentialPasteSession: Equatable, Sendable {
    static let maximumItemCount = 50
    static let maximumUTF8Bytes = 16 * 1024 * 1024
    static let inactivityTimeout: TimeInterval = 10 * 60

    struct Occurrence: Identifiable, Equatable, Sendable {
        let id: UUID
        let pasteboardGeneration: Int
        let text: String
        let capturedAt: Date

        var utf8ByteCount: Int { text.utf8.count }
    }

    enum Failure: Equatable, Sendable {
        case accessibilityPermissionRequired
        case pasteboardWriteFailed
        case pasteDispatchFailed
    }

    enum Phase: Equatable, Sendable {
        case idle
        case collecting
        case pasting
        case blocked(Failure)
        case completed(itemCount: Int)
        case expired
        case cancelled
    }

    enum AppendResult: Equatable, Sendable {
        case accepted(Occurrence)
        case inactive
        case frozen
        case itemLimitReached
        case byteLimitReached
    }

    enum RequestKind: Equatable, Sendable {
        case next
        case repeatPrevious
    }

    struct Request: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: RequestKind
        let occurrence: Occurrence
    }

    enum RequestResult: Equatable, Sendable {
        case ready(Request)
        case empty
        case busy
        case unavailable
    }

    enum RequestOutcome: Equatable, Sendable {
        case success
        case failure(Failure)
    }

    enum ResolutionResult: Equatable, Sendable {
        case advanced
        case completed
        case repeated
        case failed(Failure)
        case stale
    }

    private struct InFlightRequest: Equatable, Sendable {
        let request: Request
        let resumePhase: Phase
    }

    private(set) var phase: Phase = .idle
    private(set) var occurrences: [Occurrence] = []
    private(set) var nextIndex = 0
    private(set) var totalUTF8Bytes = 0
    private(set) var lastActivityAt: Date?
    private(set) var previousSuccessfulOccurrence: Occurrence?

    private var inFlightRequest: InFlightRequest?
    /// Preserves the stable phase across a failed repeat so retrying that repeat can return there.
    private var repeatResumePhase: Phase?

    var isActive: Bool {
        switch phase {
        case .collecting, .pasting, .blocked:
            true
        case .idle, .completed, .expired, .cancelled:
            false
        }
    }

    var isRequestInFlight: Bool { inFlightRequest != nil }
    var pastedCount: Int { nextIndex }
    var remainingCount: Int { max(occurrences.count - nextIndex, 0) }

    @discardableResult
    mutating func start(at now: Date) -> Bool {
        guard !isActive else { return false }
        clearQueue()
        phase = .collecting
        lastActivityAt = now
        return true
    }

    @discardableResult
    mutating func append(
        pasteboardGeneration: Int,
        text: String,
        capturedAt: Date
    ) -> AppendResult {
        if expireIfNeeded(at: capturedAt) { return .inactive }

        switch phase {
        case .collecting:
            break
        case .pasting, .blocked:
            lastActivityAt = capturedAt
            return .frozen
        case .idle, .completed, .expired, .cancelled:
            return .inactive
        }

        lastActivityAt = capturedAt
        guard occurrences.count < Self.maximumItemCount else { return .itemLimitReached }
        let byteCount = text.utf8.count
        guard byteCount <= Self.maximumUTF8Bytes - totalUTF8Bytes else { return .byteLimitReached }

        let occurrence = Occurrence(
            id: UUID(),
            pasteboardGeneration: pasteboardGeneration,
            text: text,
            capturedAt: capturedAt
        )
        occurrences.append(occurrence)
        totalUTF8Bytes += byteCount
        return .accepted(occurrence)
    }

    mutating func requestNext(at now: Date) -> RequestResult {
        if expireIfNeeded(at: now) { return .unavailable }
        guard isActive else { return .unavailable }
        guard inFlightRequest == nil else { return .busy }
        guard occurrences.indices.contains(nextIndex) else { return .empty }

        let request = Request(id: UUID(), kind: .next, occurrence: occurrences[nextIndex])
        inFlightRequest = InFlightRequest(request: request, resumePhase: .pasting)
        repeatResumePhase = nil
        phase = .pasting
        lastActivityAt = now
        return .ready(request)
    }

    mutating func requestRepeatPrevious(at now: Date) -> RequestResult {
        if expireIfNeeded(at: now) { return .unavailable }
        guard isActive || isCompleted else { return .unavailable }
        guard inFlightRequest == nil else { return .busy }
        guard let previousSuccessfulOccurrence else { return .empty }

        let resumePhase = repeatResumePhase ?? phase
        let request = Request(
            id: UUID(),
            kind: .repeatPrevious,
            occurrence: previousSuccessfulOccurrence
        )
        inFlightRequest = InFlightRequest(request: request, resumePhase: resumePhase)
        phase = .pasting
        lastActivityAt = now
        return .ready(request)
    }

    mutating func resolve(
        requestID: UUID,
        outcome: RequestOutcome,
        at now: Date
    ) -> ResolutionResult {
        if expireIfNeeded(at: now) { return .stale }
        guard let inFlightRequest, inFlightRequest.request.id == requestID else { return .stale }

        self.inFlightRequest = nil
        lastActivityAt = now

        switch outcome {
        case .failure(let failure):
            if inFlightRequest.request.kind == .repeatPrevious {
                repeatResumePhase = inFlightRequest.resumePhase
                phase = inFlightRequest.resumePhase
            } else {
                phase = .blocked(failure)
            }
            return .failed(failure)

        case .success:
            switch inFlightRequest.request.kind {
            case .repeatPrevious:
                phase = inFlightRequest.resumePhase
                repeatResumePhase = nil
                return .repeated

            case .next:
                previousSuccessfulOccurrence = inFlightRequest.request.occurrence
                nextIndex += 1
                if nextIndex == occurrences.count {
                    phase = .completed(itemCount: occurrences.count)
                    return .completed
                }
                phase = .pasting
                return .advanced
            }
        }
    }

    mutating func cancel() {
        clearQueue()
        phase = .cancelled
    }

    @discardableResult
    mutating func expireIfNeeded(at now: Date) -> Bool {
        guard isActive, let lastActivityAt,
              now.timeIntervalSince(lastActivityAt) >= Self.inactivityTimeout else {
            return false
        }
        clearQueue()
        phase = .expired
        return true
    }

    private var isCompleted: Bool {
        if case .completed = phase { return true }
        return false
    }

    private mutating func clearQueue() {
        occurrences.removeAll(keepingCapacity: false)
        nextIndex = 0
        totalUTF8Bytes = 0
        lastActivityAt = nil
        previousSuccessfulOccurrence = nil
        inFlightRequest = nil
        repeatResumePhase = nil
    }
}
