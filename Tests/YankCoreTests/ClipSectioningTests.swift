import Foundation
import Testing
@testable import YankCore

@Suite struct ClipSectioningTests {
    /// A fixed midday "now" so the ±hour / ±day offsets never straddle midnight.
    private let now = Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12))!

    private func item(_ n: Int, ageHours: Double = 0, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
            type: .text,
            timestamp: now.addingTimeInterval(-ageHours * 3_600),
            textContent: "item-\(n)",
            isPinned: pinned
        )
    }

    // [pinned, pinned, today, today, yesterday]
    private var sample: [ClipboardItem] {
        [
            item(1, ageHours: 200, pinned: true),
            item(2, ageHours: 1, pinned: true),
            item(3, ageHours: 0),
            item(4, ageHours: 1),
            item(5, ageHours: 25)
        ]
    }

    @Test func indexZeroAlwaysStartsSection() {
        #expect(ClipSectioning.startsSection(at: 0, in: sample))
    }

    @Test func pinnedToUnpinnedBoundary() {
        #expect(ClipSectioning.startsSection(at: 2, in: sample))   // last pinned → first unpinned
    }

    @Test func withinPinnedRunIsNotABoundary() {
        #expect(!(ClipSectioning.startsSection(at: 1, in: sample)))
    }

    @Test func sameDayUnpinnedIsNotABoundary() {
        #expect(!(ClipSectioning.startsSection(at: 3, in: sample)))  // today/today
    }

    @Test func differentDayIsABoundary() {
        #expect(ClipSectioning.startsSection(at: 4, in: sample))   // today → yesterday
    }

    @Test func outOfRangeIndexIsSafe() {
        #expect(!(ClipSectioning.startsSection(at: 99, in: sample)))
        #expect(ClipSectioning.label(at: 99, in: sample) == "")
    }

    @Test func sectionsGroupPinnedThenDays() {
        let sections = ClipSectioning.sections(sample, asOf: now)
        #expect(sections.map(\.label) == ["Pinned", "Today", "Yesterday"])
        #expect(sections.map { $0.items.count } == [2, 2, 1])
    }

    @Test func sectionsOnEmptyListIsEmpty() {
        #expect(ClipSectioning.sections([], asOf: now).isEmpty)
    }
}
