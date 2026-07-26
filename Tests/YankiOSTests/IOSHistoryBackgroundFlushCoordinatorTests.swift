import Foundation
import Testing
@testable import YankiOS

@Suite("iOS history background flush lifecycle")
@MainActor
struct IOSHistoryBackgroundFlushCoordinatorTests {
    @Test("A successful flush uses the named task and balances it once")
    func successfulFlushEndsExactlyOnce() async {
        let coordinator = IOSHistoryBackgroundFlushCoordinator()
        var names: [String] = []
        var expiration: (@MainActor () -> Void)?
        var flushCount = 0
        var endCount = 0

        let started = coordinator.flushWhenLeavingActive(
            beginBackgroundTask: { name, handler in
                names.append(name)
                expiration = handler
                return { endCount += 1 }
            },
            flush: {
                flushCount += 1
            }
        )
        await yieldUntil { endCount == 1 }

        #expect(started)
        #expect(names == [IOSHistoryBackgroundFlushCoordinator.taskName])
        #expect(flushCount == 1)
        #expect(endCount == 1)

        expiration?()
        #expect(endCount == 1)
    }

    @Test("A failed flush reports the error and still balances its task")
    func failedFlushEndsExactlyOnce() async {
        let coordinator = IOSHistoryBackgroundFlushCoordinator()
        var failureCount = 0
        var endCount = 0

        coordinator.flushWhenLeavingActive(
            beginBackgroundTask: { _, _ in
                { endCount += 1 }
            },
            flush: {
                throw BackgroundFlushTestError.writeFailed
            },
            onFailure: { error in
                if error is BackgroundFlushTestError {
                    failureCount += 1
                }
            }
        )
        await yieldUntil { endCount == 1 }

        #expect(failureCount == 1)
        #expect(endCount == 1)
    }

    @Test("Expiration cancels only the owned flush and balances immediately")
    func expirationCancelsOwnedFlush() async {
        let coordinator = IOSHistoryBackgroundFlushCoordinator()
        var expiration: (@MainActor () -> Void)?
        var flushStarted = false
        var cancellationCount = 0
        var endCount = 0

        coordinator.flushWhenLeavingActive(
            beginBackgroundTask: { _, handler in
                expiration = handler
                return { endCount += 1 }
            },
            flush: {
                flushStarted = true
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    cancellationCount += 1
                    throw CancellationError()
                }
            }
        )
        await yieldUntil { flushStarted }

        expiration?()
        await yieldUntil { cancellationCount == 1 }

        #expect(cancellationCount == 1)
        #expect(endCount == 1)

        expiration?()
        #expect(endCount == 1)
    }

    @Test("Synchronous expiration during begin balances without starting a flush")
    func synchronousExpirationDuringBeginBalances() {
        let coordinator = IOSHistoryBackgroundFlushCoordinator()
        var flushCount = 0
        var endCount = 0

        let started = coordinator.flushWhenLeavingActive(
            beginBackgroundTask: { _, expiration in
                expiration()
                return { endCount += 1 }
            },
            flush: {
                flushCount += 1
            }
        )

        #expect(!started)
        #expect(flushCount == 0)
        #expect(endCount == 1)
    }

    @Test("Overlapping lifecycle callbacks share one flush and allow a later checkpoint")
    func coalescesOverlapAndAllowsLaterFlush() async {
        let coordinator = IOSHistoryBackgroundFlushCoordinator()
        let gate = BackgroundFlushGate()
        var beginCount = 0
        var flushCount = 0
        var endCount = 0

        let firstStarted = coordinator.flushWhenLeavingActive(
            beginBackgroundTask: { _, _ in
                beginCount += 1
                return { endCount += 1 }
            },
            flush: {
                flushCount += 1
                await gate.wait()
            }
        )
        await yieldUntil { gate.hasWaiter }

        let overlappingStarted = coordinator.flushWhenLeavingActive(
            beginBackgroundTask: { _, _ in
                beginCount += 1
                return { endCount += 1 }
            },
            flush: {
                flushCount += 1
            }
        )

        #expect(firstStarted)
        #expect(!overlappingStarted)
        #expect(beginCount == 1)
        #expect(flushCount == 1)
        #expect(endCount == 0)

        gate.resume()
        await yieldUntil { endCount == 1 }

        let laterStarted = coordinator.flushWhenLeavingActive(
            beginBackgroundTask: { _, _ in
                beginCount += 1
                return { endCount += 1 }
            },
            flush: {
                flushCount += 1
            }
        )
        await yieldUntil { endCount == 2 }

        #expect(laterStarted)
        #expect(beginCount == 2)
        #expect(flushCount == 2)
        #expect(endCount == 2)
    }

    private func yieldUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }
}

private enum BackgroundFlushTestError: Error {
    case writeFailed
}

@MainActor
private final class BackgroundFlushGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var hasWaiter: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
