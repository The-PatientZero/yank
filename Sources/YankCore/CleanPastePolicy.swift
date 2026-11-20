/// Chooses when text clips are cleaned on paste.
enum CleanPasteMode: String, CaseIterable, Sendable {
    case off, chosenApps, always

    var label: String {
        switch self {
        case .off: "Off"
        case .chosenApps: "From chosen apps"
        case .always: "Always"
        }
    }
}

/// Selects text clips for cleaning using their captured source-app display names.
struct CleanPastePolicy: Equatable, Sendable {
    var mode: CleanPasteMode = .off
    var apps: Set<String> = []

    func cleansByDefault(_ item: ClipboardItem) -> Bool {
        guard item.type == .text else { return false }
        switch mode {
        case .off: return false
        case .always: return true
        case .chosenApps:
            guard let sourceApp = item.sourceApp else { return false }
            return apps.contains(sourceApp)
        }
    }
}
