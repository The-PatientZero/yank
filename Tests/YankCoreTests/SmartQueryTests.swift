import Testing
import Foundation
@testable import YankCore

@Suite struct SmartQueryTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func make(_ text: String, app: String? = nil, daysAgo: Double = 0,
                      type: ClipboardItemType = .text) -> ClipboardItem {
        ClipboardItem(type: type,
                      timestamp: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400),
                      sourceApp: app,
                      textContent: type == .text ? text : nil)
    }

    private func corpus() -> [ClipboardItem] {
        [
            make("AWS lambda timeout error", app: "Terminal", daysAgo: 0),
            make("grocery list for the weekend", app: "Notes", daysAgo: 3),
            make("AWS billing summary", app: "Safari", daysAgo: 10),
            make("", app: "Preview", daysAgo: 0, type: .image),
        ]
    }

    @Test func keywordsMatchAsAnd() {
        let results = SmartQuery(keywords: "aws error").apply(to: corpus(), now: now)
        #expect(results.count == 1)
        #expect(results.first?.textContent == "AWS lambda timeout error")
    }

    @Test func filtersByApp() {
        let results = SmartQuery(app: "safari").apply(to: corpus(), now: now)
        #expect(results.map(\.textContent) == ["AWS billing summary"])
    }

    @Test func filtersByRecency() {
        let results = SmartQuery(sinceDays: 1).apply(to: corpus(), now: now)
        // only the two clips from "today" (daysAgo 0)
        #expect(results.count == 2)
    }

    @Test func filtersByType() {
        let results = SmartQuery(type: .image).apply(to: corpus(), now: now)
        #expect(results.count == 1)
        #expect(results.first?.type == .image)
    }

    @Test func combinesConstraints() {
        let results = SmartQuery(keywords: "aws", sinceDays: 1).apply(to: corpus(), now: now)
        #expect(results.map(\.textContent) == ["AWS lambda timeout error"])
    }

    @Test func emptyQueryReturnsEverything() {
        #expect(SmartQuery().apply(to: corpus(), now: now).count == 4)
    }

    @Test func recencyBoundaryKeepsClipExactlyAtCutoff() {
        // cutoff = now − 1 day; the filter is strict `<`, so a clip whose timestamp is exactly
        // the cutoff is kept rather than dropped.
        let atCutoff = make("right at the edge", daysAgo: 1)
        let results = SmartQuery(sinceDays: 1).apply(to: [atCutoff], now: now)
        #expect(results.count == 1)
    }

    @Test func zeroOrNegativeDaysDisablesRecencyFilter() {
        #expect(SmartQuery(sinceDays: 0).apply(to: corpus(), now: now).count == 4)
        #expect(SmartQuery(sinceDays: -3).apply(to: corpus(), now: now).count == 4)
    }
}
