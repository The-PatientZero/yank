import Foundation

/// How many clips to keep. Protected (pinned / bookmarked / tagged) clips are always
/// kept regardless of the cap. Shared by both platforms' stores and settings.
///
/// Lives in the core (rather than next to the SwiftUI layout tokens it used to share a
/// file with) because the CloudKit sync module has to validate a remote raw value against
/// it, and that module can only see `YankCore`.
public enum HistoryLimit: Int, CaseIterable, Codable, Sendable {
    case essential  = 100
    case deep       = 500
    case unlimited  = 1000

    public var label: String {
        switch self {
        case .essential: return "Essential"
        case .deep:      return "Deep"
        case .unlimited: return "Unlimited"
        }
    }

    public var subtitle: String {
        switch self {
        case .essential: return "100 items"
        case .deep:      return "500 items"
        case .unlimited: return "1,000 items"
        }
    }
}
