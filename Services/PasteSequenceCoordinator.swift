import Cocoa

@MainActor
protocol PasteSequenceRuntime: AnyObject {
    var isCapturePaused: Bool { get }
    var isHotkeyAvailable: Bool { get }
    var isAccessibilityTrusted: Bool { get }
    var shortcutLabel: String { get }

    func refreshAccessibilityPermission()
    func requestAccessibilityPermission()
    func setSequenceCollectionActive(_ active: Bool)
    func dispatchPaste(
        _ text: String,
        previousApp: NSRunningApplication?
    ) async -> PasteDispatchResult
}

@MainActor
protocol PasteSequenceHUDPresenting: AnyObject {
    var state: PasteSequenceHUDState { get }

    func show()
    func close()
    func announce(_ message: String)
}

extension PasteSequenceHUDController: PasteSequenceHUDPresenting {}

@MainActor
protocol PasteSequenceHUDFactory: AnyObject {
    func makeHUD() -> any PasteSequenceHUDPresenting
}

@MainActor
private final class LivePasteSequenceRuntime: PasteSequenceRuntime {
    private let dependencies: ClipboardDependencies
    private let watcher: ClipboardWatcher

    init(dependencies: ClipboardDependencies, watcher: ClipboardWatcher) {
        self.dependencies = dependencies
        self.watcher = watcher
    }

    var isCapturePaused: Bool { watcher.isPaused }

    var isHotkeyAvailable: Bool {
        dependencies.hotkeys.isRegistered()
            && !dependencies.appStatus.hotkeyRegistrationFailed
    }

    var isAccessibilityTrusted: Bool { dependencies.axPermission.isTrusted }

    var shortcutLabel: String {
        let settings = dependencies.settings
        return "\(settings.hotkeyModifiers.displayString)\(keyCodeNames[settings.hotkeyKeyCode] ?? "?")"
    }

    func refreshAccessibilityPermission() {
        dependencies.axPermission.refresh()
    }

    func requestAccessibilityPermission() {
        AccessibilityPermission.requestPrompt()
    }

    func setSequenceCollectionActive(_ active: Bool) {
        watcher.setSequenceCollectionActive(active)
    }

    func dispatchPaste(
        _ text: String,
        previousApp: NSRunningApplication?
    ) async -> PasteDispatchResult {
        dependencies.axPermission.refresh()
        return await PasteController.pasteTextResult(
            text,
            isAccessibilityTrusted: dependencies.axPermission.isTrusted,
            previousApp: previousApp,
            focusSettleDelay: .milliseconds(50)
        )
    }
}

@MainActor
private final class LivePasteSequenceHUDFactory: PasteSequenceHUDFactory {
    func makeHUD() -> any PasteSequenceHUDPresenting {
        PasteSequenceHUDController()
    }
}

/// Owns the process-local Paste Sequence lifecycle and its non-activating HUD.
@MainActor
final class PasteSequenceCoordinator {
    private struct OwnedDispatch {
        let id: UUID
        let lifecycleGeneration: UInt64
        let requestID: UUID
        let task: Task<Void, Never>
    }

    private let runtime: any PasteSequenceRuntime
    private let hudFactory: any PasteSequenceHUDFactory
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (Duration) async throws -> Void
    private let onActivityChanged: () -> Void

    private var session = SequentialPasteSession()
    private var hud: (any PasteSequenceHUDPresenting)?
    private var timeoutTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var ownedDispatch: OwnedDispatch?
    private var lifecycleGeneration: UInt64 = 0

    private static let completionGrace: Duration = .seconds(5)
    private static let transientStatusDuration: Duration = .seconds(3)

    var isActive: Bool { session.isActive }
    var itemCount: Int { session.occurrences.count }
    var pastedCount: Int { session.pastedCount }
    var hasOwnedDispatch: Bool { ownedDispatch != nil }
    var canRepeatPrevious: Bool {
        session.isActive
            && !session.isRequestInFlight
            && session.previousSuccessfulOccurrence != nil
    }

    convenience init(
        dependencies: ClipboardDependencies,
        watcher: ClipboardWatcher,
        onActivityChanged: @escaping () -> Void
    ) {
        self.init(
            runtime: LivePasteSequenceRuntime(dependencies: dependencies, watcher: watcher),
            hudFactory: LivePasteSequenceHUDFactory(),
            onActivityChanged: onActivityChanged
        )
    }

    init(
        runtime: any PasteSequenceRuntime,
        hudFactory: any PasteSequenceHUDFactory,
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task<Never, Never>.sleep(for: $0)
        },
        onActivityChanged: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.hudFactory = hudFactory
        self.now = now
        self.sleep = sleep
        self.onActivityChanged = onActivityChanged
    }

    /// Returns true when the sequence consumed the global shortcut.
    func handleShortcut() -> Bool {
        guard session.isActive else { return false }
        pasteNext()
        return true
    }

    func toggle() {
        if session.isActive {
            cancel()
        } else {
            start()
        }
    }

    func start() {
        guard !runtime.isCapturePaused else {
            showPrerequisite(.capturePaused)
            return
        }
        guard runtime.isHotkeyAvailable else {
            showPrerequisite(.hotkeyUnavailable)
            return
        }
        runtime.refreshAccessibilityPermission()
        guard runtime.isAccessibilityTrusted else {
            runtime.requestAccessibilityPermission()
            showPrerequisite(.accessibilityUnavailable)
            return
        }

        graceTask?.cancel()
        graceTask = nil
        guard !session.isActive else { return }
        invalidateOwnedDispatch()
        guard session.start(at: now()) else { return }
        runtime.setSequenceCollectionActive(true)
        presentHUD()
        hud?.announce("Paste sequence started. Copy text to add items.")
        resetTimeout()
        onActivityChanged()
    }

    func record(pasteboardGeneration: Int, text: String, capturedAt: Date) {
        guard !expireIfNeeded(at: capturedAt) else { return }
        switch session.append(
            pasteboardGeneration: pasteboardGeneration,
            text: text,
            capturedAt: capturedAt
        ) {
        case .accepted:
            presentHUD()
            let count = session.occurrences.count
            hud?.announce(count == 1
                ? "Added to paste sequence. One item."
                : "Added to paste sequence. \(count) items.")
            resetTimeout()
        case .itemLimitReached, .byteLimitReached:
            presentHUD(phase: .blocked(.capacityReached))
            hud?.announce("Paste sequence limit reached.")
            resetTimeout()
        case .frozen:
            resetTimeout()
        case .inactive:
            break
        }
    }

    func hotkeyRegistrationDidFail() {
        guard session.isActive else { return }
        discard()
        showPrerequisite(.hotkeyUnavailable)
    }

    func cancel() {
        invalidateOwnedDispatch()
        timeoutTask?.cancel()
        timeoutTask = nil
        graceTask?.cancel()
        graceTask = nil
        session.cancel()
        runtime.setSequenceCollectionActive(false)
        presentHUD()
        hud?.announce("Paste sequence cancelled.")
        scheduleHUDClose(after: Self.transientStatusDuration)
        onActivityChanged()
    }

    func discard() {
        tearDown()
        onActivityChanged()
    }

    func stop() {
        tearDown()
    }

    private func tearDown() {
        invalidateOwnedDispatch()
        timeoutTask?.cancel()
        timeoutTask = nil
        graceTask?.cancel()
        graceTask = nil
        session.cancel()
        runtime.setSequenceCollectionActive(false)
        hud?.close()
    }

    private func pasteNext() {
        let currentDate = now()
        guard !expireIfNeeded(at: currentDate) else { return }
        switch session.requestNext(at: currentDate) {
        case .ready(let request):
            runtime.setSequenceCollectionActive(false)
            presentHUD()
            resetTimeout()
            dispatch(request, previousApp: nil)
        case .empty:
            presentHUD()
            hud?.announce("Paste sequence is empty. Copy text to add an item.")
        case .busy, .unavailable:
            break
        }
    }

    func repeatPrevious(previousApp: NSRunningApplication? = nil) {
        let currentDate = now()
        guard !expireIfNeeded(at: currentDate) else { return }
        switch session.requestRepeatPrevious(at: currentDate) {
        case .ready(let request):
            presentHUD()
            resetTimeout()
            dispatch(request, previousApp: previousApp)
        case .empty, .busy, .unavailable:
            break
        }
    }

    private func dispatch(
        _ request: SequentialPasteSession.Request,
        previousApp: NSRunningApplication?
    ) {
        guard ownedDispatch == nil else { return }
        let dispatchID = UUID()
        let generation = lifecycleGeneration
        let runtime = runtime
        let task = Task { @MainActor [weak self, runtime] in
            let result = await runtime.dispatchPaste(
                request.occurrence.text,
                previousApp: previousApp
            )
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleGeneration == generation,
                  self.ownedDispatch?.id == dispatchID,
                  self.ownedDispatch?.lifecycleGeneration == generation,
                  self.ownedDispatch?.requestID == request.id else {
                return
            }
            self.ownedDispatch = nil
            self.resolve(request, result: result)
        }
        ownedDispatch = OwnedDispatch(
            id: dispatchID,
            lifecycleGeneration: generation,
            requestID: request.id,
            task: task
        )
    }

    private func resolve(
        _ request: SequentialPasteSession.Request,
        result: PasteDispatchResult
    ) {
        let resolution = session.resolve(
            requestID: request.id,
            outcome: requestOutcome(for: result),
            at: now()
        )
        handle(resolution)
    }

    private func handle(_ resolution: SequentialPasteSession.ResolutionResult) {
        switch resolution {
        case .advanced:
            presentHUD()
            hud?.announce("Pasted item \(session.pastedCount) of \(session.occurrences.count).")
            resetTimeout()
        case .completed:
            complete()
        case .repeated:
            presentHUD()
            hud?.announce("Repeated previous item.")
            if session.isActive {
                resetTimeout()
            } else {
                scheduleCompletionGrace()
            }
        case .failed(let failure):
            handleFailure(failure)
        case .stale:
            if session.phase == .expired { showExpired() }
        }
    }

    private func complete() {
        runtime.setSequenceCollectionActive(false)
        timeoutTask?.cancel()
        timeoutTask = nil
        presentHUD()
        hud?.announce("Paste sequence complete. \(session.pastedCount) items pasted.")
        scheduleCompletionGrace()
        onActivityChanged()
    }

    private func handleFailure(_ failure: SequentialPasteSession.Failure) {
        presentHUD(phase: .blocked(hudProblem(for: failure)))
        if failure == .accessibilityPermissionRequired {
            runtime.requestAccessibilityPermission()
        }
        hud?.announce("Paste was not sent. The current item is ready to retry.")
        if session.isActive {
            resetTimeout()
        } else {
            scheduleCompletionGrace()
            onActivityChanged()
        }
    }

    private func resetTimeout() {
        timeoutTask?.cancel()
        guard session.isActive else { return }
        let generation = lifecycleGeneration
        let sleep = sleep
        timeoutTask = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(.seconds(SequentialPasteSession.inactivityTimeout))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleGeneration == generation,
                  self.session.expireIfNeeded(at: self.now()) else {
                return
            }
            self.showExpired()
        }
    }

    private func showExpired() {
        invalidateOwnedDispatch()
        timeoutTask?.cancel()
        timeoutTask = nil
        runtime.setSequenceCollectionActive(false)
        presentHUD()
        hud?.announce("Paste sequence expired.")
        scheduleHUDClose(after: Self.transientStatusDuration)
        onActivityChanged()
    }

    @discardableResult
    private func expireIfNeeded(at date: Date) -> Bool {
        guard session.expireIfNeeded(at: date) else { return false }
        showExpired()
        return true
    }

    private func invalidateOwnedDispatch() {
        lifecycleGeneration &+= 1
        ownedDispatch?.task.cancel()
        ownedDispatch = nil
    }
}

private extension PasteSequenceCoordinator {
    func showPrerequisite(_ problem: PasteSequenceHUDProblem) {
        graceTask?.cancel()
        let hud = ensureHUD()
        hud.state.phase = .blocked(problem)
        hud.state.itemCount = 0
        hud.state.nextIndex = 0
        hud.state.shortcut = shortcutLabel
        hud.show()
        hud.announce(hud.state.detailText)
        scheduleHUDClose(after: .seconds(problem == .accessibilityUnavailable ? 8 : 4))
    }

    func presentHUD(phase: PasteSequenceHUDPhase? = nil) {
        let hud = ensureHUD()
        hud.state.phase = phase ?? hudPhase(for: session.phase)
        hud.state.itemCount = session.occurrences.count
        hud.state.nextIndex = session.nextIndex
        hud.state.shortcut = shortcutLabel
        hud.show()
    }

    func ensureHUD() -> any PasteSequenceHUDPresenting {
        if let hud { return hud }
        let created = hudFactory.makeHUD()
        hud = created
        return created
    }

    var shortcutLabel: String {
        runtime.shortcutLabel
    }

    func scheduleCompletionGrace() {
        graceTask?.cancel()
        let generation = lifecycleGeneration
        let sleep = sleep
        graceTask = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(Self.completionGrace)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleGeneration == generation else {
                return
            }
            if case .completed = self.session.phase {
                self.session.cancel()
                self.hud?.close()
            }
            self.graceTask = nil
        }
    }

    func scheduleHUDClose(after delay: Duration) {
        graceTask?.cancel()
        let generation = lifecycleGeneration
        let sleep = sleep
        graceTask = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleGeneration == generation else {
                return
            }
            self.hud?.close()
            self.graceTask = nil
        }
    }

    func requestOutcome(for result: PasteDispatchResult) -> SequentialPasteSession.RequestOutcome {
        switch result {
        case .dispatched:
            return .success
        case .cancelled:
            return .failure(.pasteDispatchFailed)
        case .accessibilityUnavailable:
            return .failure(.accessibilityPermissionRequired)
        case .pasteboardWriteFailed:
            return .failure(.pasteboardWriteFailed)
        case .missingPayload, .syntheticEventFailed:
            return .failure(.pasteDispatchFailed)
        }
    }

    func hudPhase(for phase: SequentialPasteSession.Phase) -> PasteSequenceHUDPhase {
        switch phase {
        case .idle, .collecting: return .collecting
        case .pasting: return .pasting
        case .blocked(let failure): return .blocked(hudProblem(for: failure))
        case .completed: return .completed
        case .expired: return .expired
        case .cancelled: return .cancelled
        }
    }

    func hudProblem(for failure: SequentialPasteSession.Failure) -> PasteSequenceHUDProblem {
        switch failure {
        case .accessibilityPermissionRequired: return .accessibilityUnavailable
        case .pasteboardWriteFailed: return .pasteboardWriteFailed
        case .pasteDispatchFailed: return .syntheticEventFailed
        }
    }
}
