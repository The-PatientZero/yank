import Foundation

/// A structured interpretation of a free-text ("natural-language") search phrase, applied
/// purely over the clip list. The model parses a phrase into this; the filtering here is
/// deterministic and headlessly tested. Literal search (`ClipQuery`) is untouched.
public struct SmartQuery: Equatable, Sendable {
    public var keywords: String
    public var app: String?
    public var sinceDays: Int?
    public var type: ClipboardItemType?

    public init(keywords: String = "", app: String? = nil, sinceDays: Int? = nil, type: ClipboardItemType? = nil) {
        self.keywords = keywords
        self.app = app
        self.sinceDays = sinceDays
        self.type = type
    }

    /// Filter `items` (already visibility-filtered by the caller), preserving order. Keywords
    /// match as AND across whitespace-separated words via `ClipboardItem.matches`, so word
    /// order and spacing in the phrase don't matter.
    public func apply(to items: [ClipboardItem], now: Date = Date()) -> [ClipboardItem] {
        let words = keywords.split(whereSeparator: \.isWhitespace).map(String.init)
        let cutoff = sinceDays.flatMap { $0 > 0 ? now.addingTimeInterval(-Double($0) * 86_400) : nil }
        return items.filter { item in
            if let type, item.type != type { return false }
            if let app, !app.isEmpty, item.sourceApp?.localizedCaseInsensitiveContains(app) != true { return false }
            if let cutoff, item.timestamp < cutoff { return false }
            for word in words where !item.matches(word) { return false }
            return true
        }
    }
}

/// Parses a free-text phrase into a `SmartQuery` on-device. Implemented by the Foundation
/// Models parser on macOS 26+; framework-free here for testability.
public protocol QueryParser: Sendable {
    func parse(_ phrase: String) async -> SmartQuery
}
