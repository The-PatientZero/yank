import AppKit
import Testing
@testable import Yank

@Suite("Plain Text Paste Dispatch")
@MainActor
struct PasteControllerTests {
    @Test("Missing text is rejected before writing")
    func missingTextIsRejected() async {
        let pasteboard = makePasteboard()

        let result = await PasteController.pasteTextResult(
            "",
            pasteboard: pasteboard,
            isAccessibilityTrusted: true,
            focusSettleDelay: .zero,
            eventDispatcher: { true }
        )

        #expect(result == .missingPayload)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("Missing Accessibility permission does not alter the pasteboard")
    func missingAccessibilityDoesNotWrite() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("existing", forType: .string)

        let result = await PasteController.pasteTextResult(
            "queued",
            pasteboard: pasteboard,
            isAccessibilityTrusted: false,
            focusSettleDelay: .zero,
            eventDispatcher: { true }
        )

        #expect(result == .accessibilityUnavailable)
        #expect(pasteboard.string(forType: .string) == "existing")
    }

    @Test("A pasteboard write failure is reported without dispatching events")
    func pasteboardWriteFailureIsReported() async {
        let pasteboard = makePasteboard()
        var dispatchedEvent = false

        let result = await PasteController.pasteTextResult(
            "queued",
            pasteboard: pasteboard,
            isAccessibilityTrusted: true,
            focusSettleDelay: .zero,
            pasteboardWriter: { _, _ in false },
            eventDispatcher: {
                dispatchedEvent = true
                return true
            }
        )

        #expect(result == .pasteboardWriteFailed)
        #expect(!dispatchedEvent)
    }

    @Test("Synthetic event creation failure is reported")
    func syntheticEventFailureIsReported() async {
        let result = await PasteController.pasteTextResult(
            "queued",
            pasteboard: makePasteboard(),
            isAccessibilityTrusted: true,
            focusSettleDelay: .zero,
            eventDispatcher: { false }
        )

        #expect(result == .syntheticEventFailed)
    }

    @Test("Successful dispatch returns the exact written generation")
    func successfulDispatchReturnsGeneration() async throws {
        let pasteboard = makePasteboard()

        let result = await PasteController.pasteTextResult(
            "queued",
            pasteboard: pasteboard,
            isAccessibilityTrusted: true,
            focusSettleDelay: .zero,
            eventDispatcher: { true }
        )

        let generation = try #require(result.pasteboardGeneration)
        #expect(generation == pasteboard.changeCount)
        #expect(pasteboard.string(forType: .string) == "queued")
    }

    @Test("Target activation settles before the pasteboard write and event dispatch")
    func targetActivationPrecedesPaste() async throws {
        let target = try #require(
            NSRunningApplication(
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        )
        var events: [String] = []

        let result = await PasteController.pasteTextResult(
            "queued",
            pasteboard: makePasteboard(),
            isAccessibilityTrusted: true,
            previousApp: target,
            targetActivator: { app in
                #expect(app?.processIdentifier == target.processIdentifier)
                events.append("activate")
            },
            focusSettleDelay: .zero,
            focusSettler: { _ in events.append("settle") },
            pasteboardWriter: { _, _ in
                events.append("write")
                return true
            },
            eventDispatcher: {
                events.append("event")
                return true
            }
        )

        #expect(result.pasteboardGeneration != nil)
        #expect(events == ["activate", "settle", "write", "event"])
    }

    @Test("Cancellation during focus settle leaves the pasteboard and target untouched")
    func cancellationDuringFocusSettleHasNoSideEffects() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("existing", forType: .string)
        let gate = PasteFocusSettlementGate()
        var writeAttempted = false
        var eventDispatched = false

        let task = Task { @MainActor in
            await PasteController.pasteTextResult(
                "queued",
                pasteboard: pasteboard,
                isAccessibilityTrusted: true,
                focusSettleDelay: .seconds(1),
                focusSettler: { _ in await gate.wait() },
                pasteboardWriter: { _, _ in
                    writeAttempted = true
                    return true
                },
                eventDispatcher: {
                    eventDispatched = true
                    return true
                }
            )
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        let result = await task.value

        #expect(result == .cancelled)
        #expect(pasteboard.string(forType: .string) == "existing")
        #expect(!writeAttempted)
        #expect(!eventDispatched)
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("YankTests.\(UUID().uuidString)"))
    }
}

private extension PasteDispatchResult {
    var pasteboardGeneration: Int? {
        guard case .dispatched(let generation) = self else { return nil }
        return generation
    }
}

private actor PasteFocusSettlementGate {
    private var isEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if isEntered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
