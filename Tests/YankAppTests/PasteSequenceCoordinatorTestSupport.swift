import AppKit
@testable import Yank

@MainActor
final class PasteSequenceCoordinatorFixture {
    let clock = TestClock()
    let runtime = FakePasteSequenceRuntime()
    let hud = FakePasteSequenceHUD()
    let hudFactory: FakePasteSequenceHUDFactory
    let activity = ActivityCounter()
    let coordinator: PasteSequenceCoordinator

    init() {
        hudFactory = FakePasteSequenceHUDFactory(hud: hud)
        coordinator = PasteSequenceCoordinator(
            runtime: runtime,
            hudFactory: hudFactory,
            now: { [clock] in clock.date },
            sleep: { duration in
                try await Task<Never, Never>.sleep(for: duration)
            },
            onActivityChanged: { [activity] in activity.count += 1 }
        )
    }
}

@MainActor
final class FakePasteSequenceRuntime: PasteSequenceRuntime {
    var isCapturePaused = false
    var isHotkeyAvailable = true
    var isAccessibilityTrusted = true
    var shortcutLabel = "⌘⇧V"

    var accessibilityRefreshCount = 0
    var accessibilityPromptCount = 0
    var collectionStates: [Bool] = []
    let dispatchProbe = DispatchProbe()

    func refreshAccessibilityPermission() {
        accessibilityRefreshCount += 1
    }

    func requestAccessibilityPermission() {
        accessibilityPromptCount += 1
    }

    func setSequenceCollectionActive(_ active: Bool) {
        collectionStates.append(active)
    }

    func dispatchPaste(
        _ text: String,
        previousApp: NSRunningApplication?
    ) async -> PasteDispatchResult {
        await dispatchProbe.dispatch(text, previousApp: previousApp)
    }
}

@MainActor
final class FakePasteSequenceHUD: PasteSequenceHUDPresenting {
    let state = PasteSequenceHUDState()
    var showCount = 0
    var closeCount = 0
    var announcements: [String] = []

    func show() {
        showCount += 1
    }

    func close() {
        closeCount += 1
    }

    func announce(_ message: String) {
        announcements.append(message)
    }
}

@MainActor
final class FakePasteSequenceHUDFactory: PasteSequenceHUDFactory {
    private let hud: FakePasteSequenceHUD
    var makeCount = 0

    init(hud: FakePasteSequenceHUD) {
        self.hud = hud
    }

    func makeHUD() -> any PasteSequenceHUDPresenting {
        makeCount += 1
        return hud
    }
}

@MainActor
final class DispatchProbe {
    private struct PendingDispatch {
        let id: UUID
        let continuation: CheckedContinuation<PasteDispatchResult, Never>
    }

    var ignoresCancellation = false
    private(set) var texts: [String] = []
    private(set) var targetProcessIdentifiers: [pid_t?] = []
    private(set) var cancellationCount = 0
    private var pending: [PendingDispatch] = []

    var pendingCount: Int { pending.count }

    func dispatch(
        _ text: String,
        previousApp: NSRunningApplication?
    ) async -> PasteDispatchResult {
        let id = UUID()
        texts.append(text)
        targetProcessIdentifiers.append(previousApp?.processIdentifier)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.append(PendingDispatch(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func resumeNext(with result: PasteDispatchResult) {
        guard !pending.isEmpty else { return }
        let dispatch = pending.removeFirst()
        dispatch.continuation.resume(returning: result)
    }

    private func cancel(id: UUID) {
        cancellationCount += 1
        guard !ignoresCancellation,
              let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        let dispatch = pending.remove(at: index)
        dispatch.continuation.resume(returning: .cancelled)
    }
}

@MainActor
final class TestClock {
    var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
}

@MainActor
final class ActivityCounter {
    var count = 0
}

enum PasteSequenceCoordinatorTestError: Error {
    case timedOut
}
