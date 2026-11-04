import Foundation

/// How many clips to keep. Protected (pinned/bookmarked/tagged) clips are always kept regardless
/// of the cap. Lives in the core rather than with SwiftUI layout tokens because the CloudKit sync
/// module validates a remote raw value against it and can only see `YankCore`.
public enum HistoryLimit: Int, CaseIterable, Codable, Sendable {
    /// Keeps up to 100 clips.
    case essential  = 100
    /// Keeps up to 500 clips.
    case deep       = 500
    /// Keeps up to 1,000 clips, the largest cap.
    case unlimited  = 1000

    /// A short name for the limit.
    public var label: String {
        switch self {
        case .essential: return "Essential"
        case .deep:      return "Deep"
        case .unlimited: return "Unlimited"
        }
    }

    /// A caption stating the cap, such as "100 items".
    public var subtitle: String {
        switch self {
        case .essential: return "100 items"
        case .deep:      return "500 items"
        case .unlimited: return "1,000 items"
        }
    }
}
