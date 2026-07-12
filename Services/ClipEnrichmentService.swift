import AppKit

/// Runs on-device AI tagging after a capture: debounced, off the hot path, text-only, and
/// gated by the opt-in setting. Writes suggestions back via the store's `setAIEnrichment`,
/// which mirrors the proven `ocrText` write-back rail. The gating rules live in the pure,
/// headlessly tested `ClipEnrichmentPolicy`. Excluded/concealed clips never reach the store,
/// so the capture pipeline's privacy gate already covers what this can see.
@MainActor
final class ClipEnrichmentService {
    private let store: ClipboardStore
    private let enricher: ClipEnricher
    private let settings: SettingsManager
    private var captureObserver: NSObjectProtocol?
    private var debounce: DispatchWorkItem?
    private var running = false

    private static let debounceDelay: TimeInterval = 0.4

    init(store: ClipboardStore,
         enricher: ClipEnricher = FoundationModelEnricher(),
         settings: SettingsManager = .shared) {
        self.store = store
        self.enricher = enricher
        self.settings = settings
    }

    func start() {
        guard captureObserver == nil else { return }
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
    }

    private func scheduleEnrichment() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.enrichLatest() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: work)
    }

    private func enrichLatest() async {
        guard !running,
              let item = store.items.first,
              ClipEnrichmentPolicy.shouldEnrich(item, enabled: settings.aiTaggingEnabled),
              let text = item.textContent else { return }

        running = true
        defer { running = false }

        let result = await enricher.enrich(text)
        let tags = AITagCleaner.clean(result.tags, existing: item.tags)
        // The clip may have changed during the await — re-find and only stamp if still un-enriched.
        guard let current = store.items.first(where: { $0.id == item.id }), current.aiEnrichedAt == nil else { return }
        store.setAIEnrichment(tags: tags, title: nil, for: current)  // empty is fine: marks the clip done
    }
}
