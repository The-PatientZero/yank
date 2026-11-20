import AppKit
import Foundation
import Testing
@testable import Yank

@Suite("Paste Sequence Coordinator", .serialized)
@MainActor
struct PasteSequenceCoordinatorTests {
    private typealias Fixture = PasteSequenceCoordinatorFixture

    @Test("Start refuses when clipboard capture is paused")
    func startRefusesWhenCaptureIsPaused() {
        let fixture = Fixture()
        fixture.runtime.isCapturePaused = true

        fixture.coordinator.start()

        #expect(!fixture.coordinator.isActive)
        #expect(fixture.runtime.collectionStates.isEmpty)
        #expect(fixture.hud.state.phase == .blocked(.capturePaused))
        #expect(fixture.hudFactory.makeCount == 1)
    }

    @Test("Start refuses when the paste shortcut is unavailable")
    func startRefusesWhenHotkeyIsUnavailable() {
        let fixture = Fixture()
        fixture.runtime.isHotkeyAvailable = false

        fixture.coordinator.start()

        #expect(!fixture.coordinator.isActive)
        #expect(fixture.runtime.accessibilityRefreshCount == 0)
        #expect(fixture.runtime.collectionStates.isEmpty)
        #expect(fixture.hud.state.phase == .blocked(.hotkeyUnavailable))
    }

    @Test("Start refuses and prompts when Accessibility is unavailable")
    func startRefusesWhenAccessibilityIsUnavailable() {
        let fixture = Fixture()
        fixture.runtime.isAccessibilityTrusted = false

        fixture.coordinator.start()

        #expect(!fixture.coordinator.isActive)
        #expect(fixture.runtime.accessibilityRefreshCount == 1)
        #expect(fixture.runtime.accessibilityPromptCount == 1)
        #expect(fixture.runtime.collectionStates.isEmpty)
        #expect(fixture.hud.state.phase == .blocked(.accessibilityUnavailable))
    }

    @Test("Successful start enables collection and reports activity")
    func successfulStartEnablesCollection() {
        let fixture = Fixture()
        defer { fixture.coordinator.stop() }

        fixture.coordinator.start()

        #expect(fixture.coordinator.isActive)
        #expect(fixture.runtime.collectionStates == [true])
        #expect(fixture.activity.count == 1)
        #expect(fixture.hud.state.phase == .collecting)
        #expect(fixture.hudFactory.makeCount == 1)
    }

    @Test("An inactive shortcut falls through")
    func inactiveShortcutFallsThrough() {
        let fixture = Fixture()

        #expect(!fixture.coordinator.handleShortcut())
        #expect(fixture.runtime.dispatchProbe.texts.isEmpty)
        #expect(fixture.hudFactory.makeCount == 0)
    }

    @Test("An active empty shortcut is consumed without dispatch")
    func activeEmptyShortcutIsConsumedWithoutDispatch() {
        let fixture = Fixture()
        defer { fixture.coordinator.stop() }
        fixture.coordinator.start()

        #expect(fixture.coordinator.handleShortcut())
        #expect(fixture.runtime.dispatchProbe.texts.isEmpty)
        #expect(fixture.coordinator.isActive)
    }

    @Test("The shortcut dispatches the queued occurrence and stops collection")
    func shortcutDispatchesQueuedOccurrence() async throws {
        let fixture = Fixture()
        defer { fixture.coordinator.stop() }
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "first",
            capturedAt: fixture.clock.date
        )

        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }

        #expect(fixture.runtime.dispatchProbe.texts == ["first"])
        #expect(fixture.runtime.collectionStates == [true, false])
        #expect(fixture.coordinator.hasOwnedDispatch)
    }

    @Test("Duplicate occurrences dispatch in FIFO order")
    func duplicateOccurrencesDispatchInFIFOOrder() async throws {
        let fixture = Fixture()
        defer { fixture.coordinator.stop() }
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "same",
            capturedAt: fixture.clock.date
        )
        fixture.coordinator.record(
            pasteboardGeneration: 11,
            text: "same",
            capturedAt: fixture.clock.date.addingTimeInterval(1)
        )

        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }
        fixture.runtime.dispatchProbe.resumeNext(with: .dispatched(pasteboardGeneration: 20))
        try await waitUntil {
            fixture.coordinator.pastedCount == 1 && !fixture.coordinator.hasOwnedDispatch
        }

        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }
        fixture.runtime.dispatchProbe.resumeNext(with: .dispatched(pasteboardGeneration: 21))
        try await waitUntil { fixture.coordinator.pastedCount == 2 }

        #expect(fixture.runtime.dispatchProbe.texts == ["same", "same"])
        #expect(!fixture.coordinator.isActive)
    }

    @Test("Repeat Previous replays the last success without advancing")
    func repeatPreviousDoesNotAdvance() async throws {
        let fixture = Fixture()
        let target = try #require(
            NSRunningApplication(
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        )
        defer { fixture.coordinator.stop() }
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "first",
            capturedAt: fixture.clock.date
        )
        fixture.coordinator.record(
            pasteboardGeneration: 11,
            text: "second",
            capturedAt: fixture.clock.date.addingTimeInterval(1)
        )

        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }
        fixture.runtime.dispatchProbe.resumeNext(with: .dispatched(pasteboardGeneration: 20))
        try await waitUntil { fixture.coordinator.pastedCount == 1 }
        #expect(fixture.coordinator.canRepeatPrevious)

        fixture.coordinator.repeatPrevious(previousApp: target)
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }
        #expect(!fixture.coordinator.canRepeatPrevious)
        #expect(fixture.runtime.dispatchProbe.texts == ["first", "first"])
        #expect(
            fixture.runtime.dispatchProbe.targetProcessIdentifiers
                == [nil, target.processIdentifier]
        )
        fixture.runtime.dispatchProbe.resumeNext(with: .dispatched(pasteboardGeneration: 21))
        try await waitUntil { fixture.coordinator.canRepeatPrevious }

        #expect(fixture.coordinator.pastedCount == 1)
        #expect(fixture.coordinator.itemCount == 2)
        #expect(fixture.coordinator.isActive)
    }

    @Test("Cancel cancels the owned dispatch and ignores its late success")
    func cancelCancelsOwnedDispatchAndIgnoresLateSuccess() async throws {
        let fixture = Fixture()
        fixture.runtime.dispatchProbe.ignoresCancellation = true
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "old",
            capturedAt: fixture.clock.date
        )
        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }

        fixture.coordinator.cancel()
        try await waitUntil { fixture.runtime.dispatchProbe.cancellationCount == 1 }
        fixture.runtime.dispatchProbe.resumeNext(with: .dispatched(pasteboardGeneration: 20))
        await Task.yield()

        #expect(!fixture.coordinator.hasOwnedDispatch)
        #expect(!fixture.coordinator.isActive)
        #expect(fixture.coordinator.pastedCount == 0)
        #expect(fixture.runtime.collectionStates.last == false)
        #expect(fixture.hud.state.phase == .cancelled)
    }

    @Test("An old completion cannot advance or clear a restarted session")
    func staleCompletionCannotAdvanceRestartedSession() async throws {
        let fixture = Fixture()
        defer { fixture.coordinator.stop() }
        fixture.runtime.dispatchProbe.ignoresCancellation = true
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "old",
            capturedAt: fixture.clock.date
        )
        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }

        fixture.coordinator.cancel()
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 11,
            text: "new",
            capturedAt: fixture.clock.date.addingTimeInterval(1)
        )
        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 2 }

        fixture.runtime.dispatchProbe.resumeNext(with: .dispatched(pasteboardGeneration: 20))
        await Task.yield()

        #expect(fixture.coordinator.hasOwnedDispatch)
        #expect(fixture.coordinator.isActive)
        #expect(fixture.coordinator.pastedCount == 0)
        #expect(fixture.coordinator.itemCount == 1)

        fixture.runtime.dispatchProbe.resumeNext(with: .dispatched(pasteboardGeneration: 21))
        try await waitUntil { fixture.coordinator.pastedCount == 1 }
        #expect(!fixture.coordinator.isActive)
    }

    @Test("Discard cancels dispatch, disables collection, and closes the HUD")
    func discardCleansUpOwnedDispatch() async throws {
        let fixture = Fixture()
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "queued",
            capturedAt: fixture.clock.date
        )
        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }

        fixture.coordinator.discard()
        try await waitUntil { fixture.runtime.dispatchProbe.cancellationCount == 1 }

        #expect(!fixture.coordinator.hasOwnedDispatch)
        #expect(!fixture.coordinator.isActive)
        #expect(fixture.runtime.collectionStates.last == false)
        #expect(fixture.hud.closeCount == 1)
        #expect(fixture.activity.count == 2)
    }

    @Test("Stop cancels dispatch, disables collection, and closes the HUD")
    func stopCleansUpOwnedDispatch() async throws {
        let fixture = Fixture()
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "queued",
            capturedAt: fixture.clock.date
        )
        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }

        fixture.coordinator.stop()
        try await waitUntil { fixture.runtime.dispatchProbe.cancellationCount == 1 }

        #expect(!fixture.coordinator.hasOwnedDispatch)
        #expect(!fixture.coordinator.isActive)
        #expect(fixture.runtime.collectionStates.last == false)
        #expect(fixture.hud.closeCount == 1)
    }

    @Test("A hotkey failure cancels dispatch and shows the unavailable state")
    func hotkeyFailureCleansUpOwnedDispatch() async throws {
        let fixture = Fixture()
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "queued",
            capturedAt: fixture.clock.date
        )
        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }

        fixture.coordinator.hotkeyRegistrationDidFail()
        try await waitUntil { fixture.runtime.dispatchProbe.cancellationCount == 1 }

        #expect(!fixture.coordinator.hasOwnedDispatch)
        #expect(!fixture.coordinator.isActive)
        #expect(fixture.runtime.collectionStates.last == false)
        #expect(fixture.hud.state.phase == .blocked(.hotkeyUnavailable))
        #expect(fixture.activity.count == 2)
    }

    @Test("Expiration cancels the owned dispatch")
    func expirationCancelsOwnedDispatch() async throws {
        let fixture = Fixture()
        fixture.coordinator.start()
        fixture.coordinator.record(
            pasteboardGeneration: 10,
            text: "queued",
            capturedAt: fixture.clock.date
        )
        #expect(fixture.coordinator.handleShortcut())
        try await waitUntil { fixture.runtime.dispatchProbe.pendingCount == 1 }

        fixture.coordinator.record(
            pasteboardGeneration: 11,
            text: "too late",
            capturedAt: fixture.clock.date.addingTimeInterval(
                SequentialPasteSession.inactivityTimeout + 1
            )
        )
        try await waitUntil { fixture.runtime.dispatchProbe.cancellationCount == 1 }

        #expect(!fixture.coordinator.hasOwnedDispatch)
        #expect(!fixture.coordinator.isActive)
        #expect(fixture.coordinator.itemCount == 0)
        #expect(fixture.coordinator.pastedCount == 0)
        #expect(fixture.runtime.collectionStates.last == false)
        #expect(fixture.hud.state.phase == .expired)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            await Task.yield()
        }
        throw PasteSequenceCoordinatorTestError.timedOut
    }
}
