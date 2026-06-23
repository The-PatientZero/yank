import Foundation

/// Pin / day sectioning for an ordered clip list: pinned clips form a leading
/// "Pinned" group, the rest break by calendar day. Pure and shared — macOS draws
/// inline headers via `startsSection`/`label`, iOS builds `List` sections via
/// `sections`. Items are assumed already ordered (pinned first, then newest-first).
enum ClipSectioning {
    /// Whether the item at `index` begins a new section.
    static func startsSection(at index: Int, in items: [ClipboardItem],
                              calendar: Calendar = .current) -> Bool {
        guard items.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        let item = items[index], prev = items[index - 1]
        if item.isPinned != prev.isPinned { return true }
        if item.isPinned { return false }
        return !calendar.isDate(prev.timestamp, inSameDayAs: item.timestamp)
    }

    /// The header label for the section containing the item at `index`.
    static func label(at index: Int, in items: [ClipboardItem],
                      asOf now: Date = Date(), calendar: Calendar = .current) -> String {
        guard items.indices.contains(index) else { return "" }
        let item = items[index]
        return item.isPinned ? "Pinned" : item.dayGroupLabel(asOf: now, calendar: calendar)
    }

    /// Index → header label for the rows that begin a section. For index-based lists
    /// (macOS) that interleave headers inline, so the boundaries are computed once per
    /// render instead of re-derived per row.
    static func headerLabels(_ items: [ClipboardItem],
                             asOf now: Date = Date(), calendar: Calendar = .current) -> [Int: String] {
        var result: [Int: String] = [:]
        for index in items.indices where startsSection(at: index, in: items, calendar: calendar) {
            result[index] = label(at: index, in: items, asOf: now, calendar: calendar)
        }
        return result
    }

    /// The list grouped into contiguous titled sections, in order.
    static func sections(_ items: [ClipboardItem],
                         asOf now: Date = Date(), calendar: Calendar = .current) -> [ClipSection] {
        var result: [ClipSection] = []
        var label = ""
        var bucket: [ClipboardItem] = []
        for index in items.indices {
            if startsSection(at: index, in: items, calendar: calendar) {
                if !bucket.isEmpty { result.append(ClipSection(label: label, items: bucket)) }
                label = Self.label(at: index, in: items, asOf: now, calendar: calendar)
                bucket = [items[index]]
            } else {
                bucket.append(items[index])
            }
        }
        if !bucket.isEmpty { result.append(ClipSection(label: label, items: bucket)) }
        return result
    }
}

/// One titled run of clips (e.g. "Pinned", "Today"). Labels are unique within a list
/// by construction — "Pinned" leads, then each calendar day appears once and contiguously.
struct ClipSection: Identifiable {
    let label: String
    let items: [ClipboardItem]
    var id: String { label }
}
