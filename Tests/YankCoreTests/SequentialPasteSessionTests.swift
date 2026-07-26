import Foundation
import Testing
@testable import YankCore

@Suite("Sequential Paste Session")
struct SequentialPasteSessionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Repeated text copy events remain distinct and paste FIFO")
    func repeatedTextRemainsDistinctAndOrdered() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 10, text: "Alice", capturedAt: date(1))))
        #expect(isAccepted(session.append(pasteboardGeneration: 11, text: "Alice", capturedAt: date(2))))

        let first = try readyRequest(session.requestNext(at: date(3)))
        #expect(first.occurrence.pasteboardGeneration == 10)
        #expect(session.resolve(requestID: first.id, outcome: .success, at: date(4)) == .advanced)

        let second = try readyRequest(session.requestNext(at: date(5)))
        #expect(second.occurrence.pasteboardGeneration == 11)
        #expect(second.occurrence.text == "Alice")
    }

    @Test("First next request freezes the queue")
    func firstNextRequestFreezesQueue() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))

        _ = try readyRequest(session.requestNext(at: date(2)))

        #expect(session.append(pasteboardGeneration: 2, text: "two", capturedAt: date(3)) == .frozen)
        #expect(session.occurrences.map(\.text) == ["one"])
    }

    @Test("Only one paste request may be in flight")
    func serializesInFlightRequests() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))

        _ = try readyRequest(session.requestNext(at: date(2)))

        #expect(session.requestNext(at: date(3)) == .busy)
        #expect(session.isRequestInFlight)
    }

    @Test("Detectable failure retains the current occurrence")
    func failureDoesNotAdvance() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))
        let failed = try readyRequest(session.requestNext(at: date(2)))

        let result = session.resolve(
            requestID: failed.id,
            outcome: .failure(.pasteboardWriteFailed),
            at: date(3)
        )

        #expect(result == .failed(.pasteboardWriteFailed))
        #expect(session.phase == .blocked(.pasteboardWriteFailed))
        #expect(session.pastedCount == 0)
        let retry = try readyRequest(session.requestNext(at: date(4)))
        #expect(retry.occurrence.id == failed.occurrence.id)
    }

    @Test("Success advances exactly once")
    func successAdvancesExactlyOnce() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))
        #expect(isAccepted(session.append(pasteboardGeneration: 2, text: "two", capturedAt: date(2))))
        let request = try readyRequest(session.requestNext(at: date(3)))

        #expect(session.resolve(requestID: request.id, outcome: .success, at: date(4)) == .advanced)
        #expect(session.resolve(requestID: request.id, outcome: .success, at: date(5)) == .stale)
        #expect(session.pastedCount == 1)
        #expect(session.remainingCount == 1)
    }

    @Test("Repeat previous returns the last successful payload without advancing")
    func repeatPreviousDoesNotAdvance() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))
        #expect(isAccepted(session.append(pasteboardGeneration: 2, text: "two", capturedAt: date(2))))
        let first = try readyRequest(session.requestNext(at: date(3)))
        #expect(session.resolve(requestID: first.id, outcome: .success, at: date(4)) == .advanced)
        let indexBeforeRepeat = session.nextIndex

        let repeated = try readyRequest(session.requestRepeatPrevious(at: date(5)))
        #expect(repeated.kind == .repeatPrevious)
        #expect(repeated.occurrence.id == first.occurrence.id)
        #expect(session.resolve(requestID: repeated.id, outcome: .success, at: date(6)) == .repeated)
        #expect(session.nextIndex == indexBeforeRepeat)
        #expect(session.previousSuccessfulOccurrence?.id == first.occurrence.id)
    }

    @Test("Completed session can repeat its final successful payload")
    func completedSessionCanRepeatFinalPayload() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))
        let first = try readyRequest(session.requestNext(at: date(2)))
        #expect(session.resolve(requestID: first.id, outcome: .success, at: date(3)) == .completed)
        #expect(session.phase == .completed(itemCount: 1))

        let repeated = try readyRequest(session.requestRepeatPrevious(at: date(4)))
        #expect(repeated.occurrence.id == first.occurrence.id)
        #expect(session.resolve(requestID: repeated.id, outcome: .success, at: date(5)) == .repeated)
        #expect(session.phase == .completed(itemCount: 1))
        #expect(session.nextIndex == 1)
    }

    @Test("Failed repeat after completion keeps the sequence completed")
    func failedCompletedRepeatKeepsShortcutInactive() throws {
        var session = startedSession()
        _ = session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))
        let first = try readyRequest(session.requestNext(at: date(2)))
        #expect(session.resolve(requestID: first.id, outcome: .success, at: date(3)) == .completed)

        let repeated = try readyRequest(session.requestRepeatPrevious(at: date(4)))
        let resolution = session.resolve(
            requestID: repeated.id,
            outcome: .failure(.pasteDispatchFailed),
            at: date(5)
        )

        #expect(resolution == .failed(.pasteDispatchFailed))
        #expect(session.phase == .completed(itemCount: 1))
        #expect(!session.isActive)
        #expect(session.nextIndex == 1)
    }

    @Test("Item bound accepts fifty occurrences and rejects the next")
    func enforcesItemBound() {
        var session = startedSession()
        for generation in 0..<SequentialPasteSession.maximumItemCount {
            #expect(isAccepted(session.append(
                pasteboardGeneration: generation,
                text: "item-\(generation)",
                capturedAt: start
            )))
        }

        #expect(session.append(pasteboardGeneration: 51, text: "overflow", capturedAt: start) == .itemLimitReached)
        #expect(session.occurrences.count == SequentialPasteSession.maximumItemCount)
    }

    @Test("UTF-8 byte bound accepts sixteen MiB and rejects overflow")
    func enforcesUTF8ByteBound() {
        var session = startedSession()
        let maximumText = String(repeating: "a", count: SequentialPasteSession.maximumUTF8Bytes)

        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: maximumText, capturedAt: start)))
        #expect(session.totalUTF8Bytes == SequentialPasteSession.maximumUTF8Bytes)
        #expect(session.append(pasteboardGeneration: 2, text: "a", capturedAt: start) == .byteLimitReached)
    }

    @Test("Byte accounting uses UTF-8 rather than character count")
    func countsUTF8Bytes() {
        var session = startedSession()

        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "é", capturedAt: start)))

        #expect(session.totalUTF8Bytes == 2)
        #expect(session.occurrences.first?.utf8ByteCount == 2)
    }

    @Test("Accepted copy resets inactivity timeout")
    func acceptedCopyResetsTimeout() {
        var session = startedSession()
        let justBeforeTimeout = SequentialPasteSession.inactivityTimeout - 1
        #expect(isAccepted(session.append(
            pasteboardGeneration: 1,
            text: "one",
            capturedAt: date(justBeforeTimeout)
        )))

        let expired = session.expireIfNeeded(at: date(SequentialPasteSession.inactivityTimeout * 2 - 2))
        #expect(!expired)
        #expect(session.phase == .collecting)
    }

    @Test("Capacity-rejected copy resets inactivity timeout")
    func capacityRejectedCopyResetsTimeout() {
        var session = startedSession()
        for generation in 0..<SequentialPasteSession.maximumItemCount {
            #expect(isAccepted(session.append(
                pasteboardGeneration: generation,
                text: "item-\(generation)",
                capturedAt: start
            )))
        }

        #expect(session.append(
            pasteboardGeneration: 51,
            text: "overflow",
            capturedAt: date(SequentialPasteSession.inactivityTimeout - 1)
        ) == .itemLimitReached)
        let expired = session.expireIfNeeded(at: date(SequentialPasteSession.inactivityTimeout * 2 - 2))
        #expect(!expired)
    }

    @Test("Copy after the queue freezes resets inactivity without changing order")
    func frozenCopyResetsTimeoutWithoutAppending() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: start)))
        _ = try readyRequest(session.requestNext(at: date(1)))

        let result = session.append(
            pasteboardGeneration: 2,
            text: "later",
            capturedAt: date(SequentialPasteSession.inactivityTimeout - 1)
        )

        #expect(result == .frozen)
        #expect(session.occurrences.map(\.text) == ["one"])
        let expired = session.expireIfNeeded(at: date(SequentialPasteSession.inactivityTimeout * 2 - 2))
        #expect(!expired)
    }

    @Test("Paste attempt resets inactivity timeout")
    func pasteAttemptResetsTimeout() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: start)))
        let attemptAt = SequentialPasteSession.inactivityTimeout - 1

        _ = try readyRequest(session.requestNext(at: date(attemptAt)))

        let expired = session.expireIfNeeded(at: date(SequentialPasteSession.inactivityTimeout * 2 - 2))
        #expect(!expired)
        #expect(session.isRequestInFlight)
    }

    @Test("Successful paste resets inactivity timeout")
    func successfulPasteResetsTimeout() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: start)))
        #expect(isAccepted(session.append(pasteboardGeneration: 2, text: "two", capturedAt: start)))
        let request = try readyRequest(session.requestNext(at: date(1)))
        let successAt = SequentialPasteSession.inactivityTimeout - 1
        #expect(session.resolve(requestID: request.id, outcome: .success, at: date(successAt)) == .advanced)

        let expired = session.expireIfNeeded(at: date(SequentialPasteSession.inactivityTimeout * 2 - 2))
        #expect(!expired)
        #expect(session.phase == .pasting)
    }

    @Test("Expiration clears queue and retained previous payload")
    func expirationClearsSession() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))
        #expect(isAccepted(session.append(pasteboardGeneration: 2, text: "two", capturedAt: date(2))))
        let first = try readyRequest(session.requestNext(at: date(3)))
        #expect(session.resolve(requestID: first.id, outcome: .success, at: date(4)) == .advanced)

        let expired = session.expireIfNeeded(at: date(4 + SequentialPasteSession.inactivityTimeout))
        #expect(expired)
        #expect(session.phase == .expired)
        #expect(session.occurrences.isEmpty)
        #expect(session.previousSuccessfulOccurrence == nil)
        #expect(session.totalUTF8Bytes == 0)
    }

    @Test("Cancel clears queue and in-flight request")
    func cancelClearsSession() throws {
        var session = startedSession()
        #expect(isAccepted(session.append(pasteboardGeneration: 1, text: "one", capturedAt: date(1))))
        let request = try readyRequest(session.requestNext(at: date(2)))

        session.cancel()

        #expect(session.phase == .cancelled)
        #expect(session.occurrences.isEmpty)
        #expect(!session.isRequestInFlight)
        #expect(session.resolve(requestID: request.id, outcome: .success, at: date(3)) == .stale)
    }

    private func startedSession() -> SequentialPasteSession {
        var session = SequentialPasteSession()
        session.start(at: start)
        return session
    }

    private func date(_ offset: TimeInterval) -> Date {
        start.addingTimeInterval(offset)
    }

    private func isAccepted(_ result: SequentialPasteSession.AppendResult) -> Bool {
        if case .accepted = result { return true }
        return false
    }

    private func readyRequest(
        _ result: SequentialPasteSession.RequestResult
    ) throws -> SequentialPasteSession.Request {
        guard case .ready(let request) = result else { throw ExpectedRequestError() }
        return request
    }

    private struct ExpectedRequestError: Error {}
}
