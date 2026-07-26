import AppIntents
import UIKit

struct CaptureClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard to Yank"
    static let description = IntentDescription("Saves the current clipboard text to your Yank history.")
    static let openAppWhenRun = false

    enum CaptureError: Error, LocalizedError {
        case emptyClipboard
        case storageUnavailable
        case captureQueueFull
        case textTooLarge

        var errorDescription: String? {
            switch self {
            case .emptyClipboard:
                return "The clipboard is empty. Copy some text first, then run this action."
            case .storageUnavailable:
                return "Yank's storage is unavailable. Open Yank to check its status before retrying."
            case .captureQueueFull:
                return "Yank has pending captures. Open the app, then try again."
            case .textTooLarge:
                return "The clipboard text is too large to save."
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await Self.captureClipboard(
            resolveAppGroup: { AppGroupContainer.live() },
            readText: { UIPasteboard.general.string }
        )
        return .result(dialog: IntentDialog(stringLiteral: "Saved to Yank"))
    }

    @MainActor
    static func captureClipboard(
        resolveAppGroup: @MainActor () -> AppGroupContainer?,
        readText: @MainActor () -> String?
    ) async throws {
        guard let appGroup = resolveAppGroup() else {
            throw CaptureError.storageUnavailable
        }
        guard let text = readText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.emptyClipboard
        }
        try await enqueue(text: text, in: appGroup.shareInbox)
    }

    nonisolated static func enqueue(text: String, in inbox: ShareCaptureInbox) async throws {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try inbox.enqueue(text: text, sourceApp: "Shortcuts")
            }.value
        } catch ShareCaptureInbox.Error.quotaExceeded {
            throw CaptureError.captureQueueFull
        } catch ShareCaptureInbox.Error.textTooLarge {
            throw CaptureError.textTooLarge
        } catch {
            throw CaptureError.storageUnavailable
        }
    }
}

struct YankShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureClipIntent(),
            phrases: [
                "Save clipboard to \(.applicationName)",
                "Capture clipboard in \(.applicationName)",
                "Add clipboard to \(.applicationName)",
                "Clip this with \(.applicationName)"
            ],
            shortTitle: "Save Clipboard",
            systemImageName: "doc.on.clipboard"
        )
    }
}
