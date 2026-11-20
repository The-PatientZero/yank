import Foundation
import Testing
@testable import Yank

// `ClipboardController` wires `CoalescingTrigger` to the CloudKit remote-change pull and
// `BackoffRetryScheduler` to a failed `start()`. Both are exercised here in isolation, with
// fake operations, rather than through the controller: constructing one for real requires a
// provisioned CloudKit container and a live `HubController` menu-bar item, neither available
// in a unit test.

@Suite("Coalescing trigger")
@MainActor
struct CoalescingTriggerTests {
    @Test("A trigger arriving mid-run causes exactly one follow-up run")
    func triggerDuringRunCoalescesIntoOneFollowUp() async {
        let gate = AsyncTestGate()
        var runCount = 0
        let trigger = CoalescingTrigger {
            runCount += 1
            await gate.wait()
        }

        trigger.trigger()
        while !gate.hasWaiter { await Task.yield() }
        #expect(runCount == 1)

        // Both arrive while the first run is still in flight — coalesced into one follow-up.
        trigger.trigger()
        trigger.trigger()
        gate.resume()

        while !gate.hasWaiter { await Task.yield() }
        #expect(runCount == 2)
        gate.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(runCount == 2)
    }

    @Test("No trigger arrives while running means no follow-up run")
    func noTriggerDuringRunMeansNoFollowUp() async {
        var runCount = 0
        let trigger = CoalescingTrigger { runCount += 1 }

        trigger.trigger()
        for _ in 0..<10 { await Task.yield() }

        #expect(runCount == 1)
    }

    @Test("Cancelling mid-run drops a remembered trigger")
    func cancelDropsPendingTrigger() async {
        let gate = AsyncTestGate()
        var runCount = 0
        let trigger = CoalescingTrigger {
            runCount += 1
            await gate.wait()
        }

        trigger.trigger()
        while !gate.hasWaiter { await Task.yield() }
        trigger.trigger()
        trigger.cancel()
        gate.resume()

        for _ in 0..<10 { await Task.yield() }
        #expect(runCount == 1)
    }
}

@Suite("Backoff retry scheduler")
@MainActor
struct BackoffRetrySchedulerTests {
    @Test("A scheduled retry fires the action after its delay")
    func scheduledRetryFires() async {
        let scheduler = BackoffRetryScheduler(delays: [.milliseconds(20), .milliseconds(20)])
        var fireCount = 0

        scheduler.scheduleNext(afterAttempt: 0) { fireCount += 1 }
        #expect(fireCount == 0)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(fireCount == 1)
    }

    @Test("Cancelling before the delay elapses suppresses the action")
    func cancelSuppressesAction() async {
        let scheduler = BackoffRetryScheduler(delays: [.milliseconds(50)])
        var fireCount = 0

        scheduler.scheduleNext(afterAttempt: 0) { fireCount += 1 }
        scheduler.cancel()

        try? await Task.sleep(for: .milliseconds(300))
        #expect(fireCount == 0)
    }

    @Test("Scheduling past the end of the delay list is a no-op")
    func exhaustedScheduleIsNoOp() async {
        let scheduler = BackoffRetryScheduler(delays: [.milliseconds(10)])
        var fireCount = 0

        scheduler.scheduleNext(afterAttempt: 1) { fireCount += 1 }

        try? await Task.sleep(for: .milliseconds(300))
        #expect(fireCount == 0)
    }

    @Test("A later schedule call replaces an earlier pending one")
    func laterScheduleReplacesEarlierPending() async {
        let scheduler = BackoffRetryScheduler(delays: [.milliseconds(200), .milliseconds(20)])
        var fireCount = 0

        scheduler.scheduleNext(afterAttempt: 0) { fireCount += 1 }
        scheduler.scheduleNext(afterAttempt: 1) { fireCount += 1 }

        try? await Task.sleep(for: .milliseconds(300))
        #expect(fireCount == 1)
    }
}

@MainActor
private final class AsyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var hasWaiter: Bool { continuation != nil }

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
