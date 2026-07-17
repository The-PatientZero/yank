import AppIntents
import UIKit

struct CaptureClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard to Yank"
    static let description = IntentDescription("Saves the current clipboard text to your Yank history.")
    static let openAppWhenRun = false

    enum CaptureError: Error, LocalizedError {
        case emptyClipboard
        case storageUnavailable

        var errorDescription: String? {
            switch self {
            case .emptyClipboard:
                return "The clipboard is empty. Copy some text first, then run this action."
            case .storageUnavailable:
                return "Yank's storage is unavailable. Open Yank to check its status before retrying."
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.emptyClipboard
        }
        let store = ClipStore()
        guard !store.storageUnavailable else {
            throw CaptureError.storageUnavailable
        }
        await store.capture(text: text, sourceApp: "Action Button")
        do {
            try store.flushPendingWrites()
        } catch {
            throw CaptureError.storageUnavailable
        }
        return .result(dialog: IntentDialog(stringLiteral: "Saved to Yank"))
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
