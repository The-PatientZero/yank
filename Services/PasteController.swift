import Cocoa
import UniformTypeIdentifiers

enum PasteDispatchResult: Equatable {
    case dispatched(pasteboardGeneration: Int)
    case cancelled
    case missingPayload
    case pasteboardWriteFailed
    case accessibilityUnavailable
    case syntheticEventFailed
}

struct PasteboardWriteReceipt: Equatable, Sendable {
    let pasteboardName: String
    let generation: Int

    @MainActor
    func isCurrent(on pasteboard: NSPasteboard) -> Bool {
        pasteboardName == pasteboard.name.rawValue
            && generation == pasteboard.changeCount
    }
}

@MainActor
final class DeferredPasteboardWriteCoordinator {
    struct Intent: Equatable {
        fileprivate let id: UUID
        fileprivate let pasteboardName: String
        fileprivate let startingGeneration: Int
    }

    private var latestIntentIDByPasteboard: [String: UUID] = [:]

    func begin(for pasteboard: NSPasteboard) -> Intent {
        let intent = Intent(
            id: UUID(),
            pasteboardName: pasteboard.name.rawValue,
            startingGeneration: pasteboard.changeCount
        )
        latestIntentIDByPasteboard[intent.pasteboardName] = intent.id
        return intent
    }

    func claim(_ intent: Intent, for pasteboard: NSPasteboard) -> Bool {
        let pasteboardName = pasteboard.name.rawValue
        guard pasteboardName == intent.pasteboardName,
              latestIntentIDByPasteboard[pasteboardName] == intent.id else {
            return false
        }

        latestIntentIDByPasteboard[pasteboardName] = nil
        return pasteboard.changeCount == intent.startingGeneration
    }
}

/// Handles pasting content into the frontmost application. Caseless `enum` used purely as
/// a namespace.
@MainActor
enum PasteController {
    nonisolated static let staleTempDirectoryAge: TimeInterval = 24 * 60 * 60
    nonisolated static let pasteFileCleanupDelay: TimeInterval = 60
    // Copy has no paste moment; keep file URLs briefly without waiting for stale cleanup.
    nonisolated static let copyFileCleanupDelay: TimeInterval = 10 * 60
    static let deferredWriteCoordinator = DeferredPasteboardWriteCoordinator()

    static func paste(_ item: ClipboardItem, store: ClipboardStore,
                      axPermission: AccessibilityPermission? = nil,
                      previousApp: NSRunningApplication? = nil) {
        let pasteboard = NSPasteboard.general
        let intent = deferredWriteCoordinator.begin(for: pasteboard)
        Task { @MainActor in
            let prepared = await prepareContents(of: item, store: store)
            guard deferredWriteCoordinator.claim(intent, for: pasteboard) else {
                discardTempFiles(in: prepared.fallback)
                return
            }
            guard let receipt = writePreparedContents(
                prepared,
                to: pasteboard,
                temporaryFileCleanupDelay: pasteFileCleanupDelay
            ) else {
                // Log rather than fail silently: nothing written means no visible effect.
                Log.paste.error(
                    "Paste produced no pasteboard content for clip \(item.id, privacy: .public)"
                )
                return
            }
            store.moveToTop(item)

            if let axPermission, !axPermission.isTrusted {
                AccessibilityPermission.requestPrompt()
                showAccessibilityHUD()
                return
            }

            // Reactivate previous app, then simulate paste once it has focus. The 0.1s delay is
            // deliberate — the OS needs time to bring `previousApp` to the foreground before the
            // synthetic ⌘V lands.
            previousApp?.activate()
            simulatePasteWithCustomDelay(0.1, receipt: receipt, pasteboard: pasteboard)
        }
    }

    /// Paste a plain-text string (e.g. an image's OCR text) into the frontmost app.
    static func pasteText(_ text: String, axPermission: AccessibilityPermission? = nil,
                          previousApp: NSRunningApplication? = nil) {
        // Without Accessibility permission, text still lands on the clipboard for manual ⌘V
        // (Paste Sequence preflights permission and calls the result-bearing API directly instead).
        if let axPermission, !axPermission.isTrusted {
            guard copyTextToClipboard(text) != nil else { return }
            AccessibilityPermission.requestPrompt()
            showAccessibilityHUD()
            return
        }

        Task { @MainActor in
            let result = await pasteTextResult(
                text,
                isAccessibilityTrusted: true,
                previousApp: previousApp
            )
            switch result {
            case .pasteboardWriteFailed:
                Log.paste.error("Failed to write plain text to the pasteboard")
            case .syntheticEventFailed:
                Log.paste.error("Failed to create synthetic paste events")
            case .cancelled, .missingPayload, .accessibilityUnavailable, .dispatched:
                break
            }
        }
    }

    /// Result-bearing plain-text dispatch used by Paste Sequence and the existing text path.
    /// Target-app acceptance is not observable; `.dispatched` means the pasteboard write and
    /// synthetic event creation/post both completed.
    static func pasteTextResult(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: Bool,
        previousApp: NSRunningApplication? = nil,
        deferredWriteIntent: DeferredPasteboardWriteCoordinator.Intent? = nil,
        targetActivator: @escaping @MainActor (NSRunningApplication?) -> Void = { application in
            _ = application?.activate()
        },
        focusSettleDelay: Duration = .milliseconds(100),
        focusSettler: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task<Never, Never>.sleep(for: $0)
        },
        pasteboardWriter: @escaping @MainActor (String, NSPasteboard) -> Bool = {
            $1.setString($0, forType: .string)
        },
        eventDispatcher: @escaping @MainActor () -> Bool = { simulatePaste() }
    ) async -> PasteDispatchResult {
        guard !text.isEmpty else { return .missingPayload }
        guard isAccessibilityTrusted else { return .accessibilityUnavailable }
        let intent = deferredWriteIntent ?? deferredWriteCoordinator.begin(for: pasteboard)

        targetActivator(previousApp)
        do {
            try await focusSettler(focusSettleDelay)
        } catch {
            return .cancelled
        }
        guard !Task.isCancelled,
              deferredWriteCoordinator.claim(intent, for: pasteboard) else {
            return .cancelled
        }

        guard let receipt = performPasteboardWrite(
            to: pasteboard,
            { pasteboardWriter(text, pasteboard) }
        ) else {
            return .pasteboardWriteFailed
        }

        guard receipt.isCurrent(on: pasteboard) else { return .cancelled }
        guard eventDispatcher() else { return .syntheticEventFailed }
        return .dispatched(pasteboardGeneration: receipt.generation)
    }

    /// Smart Paste: transforms a text clip on-device, falling back to the original text on
    /// failure/unavailability. The transform result is never stored, and is awaited *before*
    /// the pasteboard write so the 0.1s focus-settle timing stays correct.
    static func pasteTransformed(_ item: ClipboardItem, as transform: TextTransform,
                                 store: ClipboardStore,
                                 transformer: TextTransformer = FoundationModelTransformer(),
                                 axPermission: AccessibilityPermission? = nil,
                                 previousApp: NSRunningApplication? = nil) {
        let pasteboard = NSPasteboard.general
        let intent = deferredWriteCoordinator.begin(for: pasteboard)
        Task { @MainActor in
            guard let original = await store.fullTextAsync(for: item), !original.isEmpty else { return }
            let result = await transformer.transform(original, as: transform) ?? original
            if let axPermission, !axPermission.isTrusted {
                guard deferredWriteCoordinator.claim(intent, for: pasteboard),
                      copyTextToClipboard(result, pasteboard: pasteboard) != nil else {
                    return
                }
                store.moveToTop(item)
                AccessibilityPermission.requestPrompt()
                showAccessibilityHUD()
                return
            }

            let dispatchResult = await pasteTextResult(
                result,
                pasteboard: pasteboard,
                isAccessibilityTrusted: true,
                previousApp: previousApp,
                deferredWriteIntent: intent
            )
            switch dispatchResult {
            case .dispatched:
                store.moveToTop(item)
            case .pasteboardWriteFailed:
                Log.paste.error("Failed to write transformed text to the pasteboard")
            case .syntheticEventFailed:
                Log.paste.error("Failed to create transformed-text paste events")
            case .cancelled, .missingPayload, .accessibilityUnavailable:
                break
            }
        }
    }

    @discardableResult
    static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        // Every paste path funnels here, so this is the one place the paste cue belongs.
        Feedback.emit(.paste)
        return true
    }

}
