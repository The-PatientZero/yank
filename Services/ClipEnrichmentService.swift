import AppKit

/// Runs on-device AI tagging after a capture: debounced, off the hot path, text-only, gated
/// by the opt-in setting. Gating logic lives in `ClipEnrichmentPolicy`. No privacy check here —
/// excluded/concealed clips never reach the store, so the capture pipeline's gate already covers it.
@MainActor
final class ClipEnrichmentService {
    private let store: ClipboardStore
    private let enricher: ClipEnricher
    private let settings: SettingsManager
    private var captureObserver: NSObjectProtocol?
    private var debounce: DispatchWorkItem?
    private var running = false
    private var rerunPending = false
    private var serviceGeneration = 0

    private let debounceDelay: TimeInterval

    init(store: ClipboardStore,
         enricher: ClipEnricher = FoundationModelEnricher(),
         settings: SettingsManager = .shared,
         debounceDelay: TimeInterval = 0.4) {
        self.store = store
        self.enricher = enricher
        self.settings = settings
        self.debounceDelay = debounceDelay
    }

    func start() {
        guard captureObserver == nil else { return }
        serviceGeneration &+= 1
        captureObserver = NotificationCenter.default.addObserver(
            forName: .yankDidCapture, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleEnrichment() }
        }
    }

    func stop() {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
        captureObserver = nil
        debounce?.cancel()
        debounce = nil
        rerunPending = false
        serviceGeneration &+= 1
    }

    private func scheduleEnrichment() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.runEnrichmentLoop() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    private func runEnrichmentLoop() async {
        guard captureObserver != nil else { return }
        if running {
            rerunPending = true
            return
        }

        running = true
        defer { running = false }

        repeat {
            rerunPending = false
            await enrichLatest()
        } while rerunPending
    }

    private func enrichLatest() async {
        guard let item = store.items.first,
              ClipEnrichmentPolicy.shouldEnrich(item, enabled: settings.aiTaggingEnabled),
              let text = item.textContent else { return }

        let generation = serviceGeneration
        let result = await enricher.enrich(text)
        guard captureObserver != nil,
              serviceGeneration == generation,
              let current = store.items.first(where: { $0.id == item.id }),
              current.textContent == text,
              ClipEnrichmentPolicy.shouldEnrich(current, enabled: settings.aiTaggingEnabled) else { return }

        let tags = AITagCleaner.clean(result.tags, existing: current.tags)
        store.setAIEnrichment(tags: tags, title: nil, for: current)  // empty is fine: marks the clip done
    }
}
