import Foundation

/// Pure conflict resolution for sync. Copies of one clip are merged field by field: pin, bookmark
/// and tags each follow their own change time, the capture time is the latest seen, and a delete
/// beats edits made after it, except a pin, bookmark or tag set after the delete. Tombstones are
/// retained so deletions keep propagating. No I/O — exhaustively testable.
public enum ClipboardMerge {
    /// How far a merged result's `modifiedAt` is pushed past its newest input when the merge
    /// changed any synced field. Yank 1.2.x keeps its own copy on an exact `modifiedAt` tie and
    /// would upload it again forever; a strictly newer result makes it take the merged copy. The
    /// interval exceeds CloudKit's one-millisecond date rounding.
    static let mergeBumpInterval: TimeInterval = 0.010

    /// How close the capture times of an arriving clip and an identical local clip must be for
    /// them to count as one copy made on two devices.
    static let crossDeviceCollapseWindow: TimeInterval = 30 * 60

    /// Reconcile two item sets into one canonical set (tombstones included), newest-first.
    /// Copies of one ID are decided together, so the result does not depend on the fold order.
    public static func reconcile(_ a: [ClipboardItem], _ b: [ClipboardItem]) -> [ClipboardItem] {
        var groups: [UUID: [ClipboardItem]] = [:]
        for item in a + b {
            groups[item.id, default: []].append(item)
        }
        return groups.values.map(mergeGroup).sorted(by: newestFirst)
    }

    /// Whether a delete at `deletedAt` beats a live copy captured or reused at `liveTimestamp`.
    /// Capturing or reusing the clip again after the delete moves `timestamp`, so it comes back.
    /// This rule looks at the capture time only; `deleteOutranksLiveCopy(deletedAt:live:)` also
    /// weighs a pin, bookmark or tag set after the delete.
    public static func deleteOutranksLiveCopy(deletedAt: Date, liveTimestamp: Date) -> Bool {
        liveTimestamp <= deletedAt
    }

    /// Whether a delete at `deletedAt` beats `live`. Like the timestamp rule, and a pinned,
    /// bookmarked or tagged copy also survives when the change that protects it is newer than the
    /// delete. Age retention dates its delete from the expired clip, so a copy another device
    /// protected meanwhile must not be lost to a device that still held it unprotected. A copy
    /// without per-field change times, from Yank 1.2.x, counts its protection as changed at
    /// `modifiedAt`, which is how 1.2.x itself orders a delete against an edit.
    public static func deleteOutranksLiveCopy(deletedAt: Date, live: ClipboardItem) -> Bool {
        guard deleteOutranksLiveCopy(deletedAt: deletedAt, liveTimestamp: live.timestamp) else { return false }
        return !(live.isProtected && protectionClock(of: live) > deletedAt)
    }

    /// When the newest of the pin, bookmark and tags that are set on `item` was changed.
    private static func protectionClock(of item: ClipboardItem) -> Date {
        var clocks: [Date] = []
        if item.isPinned { clocks.append(effectiveClock(of: item, \.pinnedAt)) }
        if item.isBookmarked { clocks.append(effectiveClock(of: item, \.bookmarkedAt)) }
        if !item.tags.isEmpty { clocks.append(effectiveClock(of: item, \.tagsAt)) }
        return clocks.max() ?? .distantPast
    }

    /// Collapses clips that arrived from another device into an identical clip already on this one
    /// (the same text copied on two devices before they synced). `arrivals` are the live clips new
    /// to this device in the pull being applied; clips in `pendingDeleteIDs` are waiting out their
    /// undo window and are never matched. Arrivals are paired oldest first, each with the newest
    /// identical local clip captured within `crossDeviceCollapseWindow` that no earlier arrival
    /// took. Of a pair the smaller clip ID survives (the ID never changes, so every device picks the
    /// same one), with both clips' pin, bookmark and tags and the later capture time; the other
    /// becomes an ordinary delete. Arrivals matching only other arrivals are left alone.
    public static func collapsingCrossDeviceDuplicates(
        _ items: [ClipboardItem],
        arrivals: Set<UUID>,
        pendingDeleteIDs: Set<UUID>
    ) -> [ClipboardItem] {
        let arrivingClips = items
            .filter { !$0.isDeleted && arrivals.contains($0.id) && !pendingDeleteIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.timestamp != rhs.timestamp
                    ? lhs.timestamp < rhs.timestamp
                    : lhs.id.uuidString < rhs.id.uuidString
            }
        guard !arrivingClips.isEmpty else { return items }

        let localClips = items.filter {
            !$0.isDeleted && !arrivals.contains($0.id) && !pendingDeleteIDs.contains($0.id)
        }
        var usedLocalIDs = Set<UUID>()
        var replacements: [UUID: ClipboardItem] = [:]

        for arrival in arrivingClips {
            let match = localClips
                .filter { local in
                    !usedLocalIDs.contains(local.id)
                        && abs(local.timestamp.timeIntervalSince(arrival.timestamp)) <= crossDeviceCollapseWindow
                        && TextCaptureIdentity.matches(local, arrival)
                }
                .max { lhs, rhs in
                    lhs.timestamp != rhs.timestamp
                        ? lhs.timestamp < rhs.timestamp
                        : lhs.id.uuidString < rhs.id.uuidString
                }
            guard let match else { continue }
            usedLocalIDs.insert(match.id)

            let (survivor, loser) = match.id.uuidString < arrival.id.uuidString
                ? (match, arrival) : (arrival, match)
            replacements[survivor.id] = absorbing(loser, into: survivor)
            replacements[loser.id] = collapseTombstone(for: loser, survivor: survivor)
        }
        guard !replacements.isEmpty else { return items }
        return items.map { replacements[$0.id] ?? $0 }
    }

    /// The survivor of a collapse: pinned or bookmarked if either clip was, with both clips' tags
    /// and the later capture time. A field set on one side only keeps that side's change time, so
    /// a flag never looks set at a time when it was not. Unchanged when the loser adds nothing.
    private static func absorbing(_ loser: ClipboardItem, into survivor: ClipboardItem) -> ClipboardItem {
        var merged = survivor
        merged.isPinned = survivor.isPinned || loser.isPinned
        merged.isBookmarked = survivor.isBookmarked || loser.isBookmarked
        merged.tags = survivor.tags + loser.tags.filter { !survivor.tags.contains($0) }
        merged.timestamp = max(survivor.timestamp, loser.timestamp)
        guard !hasSameSyncedFields(merged, as: survivor) else { return survivor }

        let survivorClocks = survivor.annotationClocks ?? AnnotationClocks(allAt: survivor.modifiedAt)
        let loserClocks = loser.annotationClocks ?? AnnotationClocks(allAt: loser.modifiedAt)
        func flagClock(
            _ survivorSet: Bool, _ loserSet: Bool, _ survivorAt: Date, _ loserAt: Date
        ) -> Date {
            if survivorSet != loserSet { return survivorSet ? survivorAt : loserAt }
            return max(survivorAt, loserAt)
        }
        let tagsAt: Date
        switch (survivor.tags.isEmpty, loser.tags.isEmpty) {
        case (false, true): tagsAt = survivorClocks.tagsAt
        case (true, false): tagsAt = loserClocks.tagsAt
        default: tagsAt = max(survivorClocks.tagsAt, loserClocks.tagsAt)
        }
        merged.annotationClocks = AnnotationClocks(
            pinnedAt: flagClock(survivor.isPinned, loser.isPinned, survivorClocks.pinnedAt, loserClocks.pinnedAt),
            bookmarkedAt: flagClock(
                survivor.isBookmarked, loser.isBookmarked, survivorClocks.bookmarkedAt, loserClocks.bookmarkedAt
            ),
            tagsAt: tagsAt
        )
        merged.modifiedAt = max(survivor.modifiedAt, loser.modifiedAt).addingTimeInterval(mergeBumpInterval)
        return merged
    }

    /// The delete for the clip a collapse removed, dated past everything either clip recorded so
    /// every device, including Yank 1.2.x, accepts it. Built like `SyncReconcile.tombstoneItems`.
    private static func collapseTombstone(for loser: ClipboardItem, survivor: ClipboardItem) -> ClipboardItem {
        let deletedAt = [loser.modifiedAt, loser.timestamp, survivor.modifiedAt, survivor.timestamp]
            .max()?.addingTimeInterval(mergeBumpInterval) ?? loser.modifiedAt
        return ClipboardItem(
            id: loser.id, type: .text, timestamp: deletedAt, modifiedAt: deletedAt, deletedAt: deletedAt
        )
    }

    /// The live items a UI should show: tombstones filtered out, order preserved.
    public static func visible(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { !$0.isDeleted }
    }

    private static func mergeGroup(_ copies: [ClipboardItem]) -> ClipboardItem {
        let live = copies.filter { !$0.isDeleted }
        let dead = copies.filter { $0.isDeleted }
        guard !live.isEmpty else { return foldByWriteClock(dead) }
        guard !dead.isEmpty else { return mergeLive(live) }

        var tombstone = foldByWriteClock(dead)
        let deletedAt = dead.compactMap(\.deletedAt).max() ?? tombstone.modifiedAt
        if live.contains(where: { !deleteOutranksLiveCopy(deletedAt: deletedAt, live: $0) }) {
            return mergeLive(live)
        }
        // The delete wins. Yank 1.2.x compares `modifiedAt` only, so lift the delete over any
        // newer edit it beat; otherwise that device would bring the clip back and push it again.
        let newestEdit = live.map(\.modifiedAt).max() ?? tombstone.modifiedAt
        if newestEdit > tombstone.modifiedAt {
            tombstone.modifiedAt = newestEdit
            tombstone.deletedAt = newestEdit
        }
        return tombstone
    }

    private static func foldByWriteClock(_ group: [ClipboardItem]) -> ClipboardItem {
        var winner = group[0]
        for item in group.dropFirst() {
            winner = orderedByWriteClock(winner, item).winner
        }
        return withDerivedFields(winner, from: group)
    }

    /// Merges live copies of one clip. The whole-clip winner is chosen by `modifiedAt`; pin,
    /// bookmark and tags are then taken from whichever copy changed that field last.
    private static func mergeLive(_ copies: [ClipboardItem]) -> ClipboardItem {
        var winner = copies[0]
        for item in copies.dropFirst() {
            winner = orderedByWriteClock(winner, item).winner
        }
        let clocked = copies.contains { $0.annotationClocks != nil }

        func latest(
            _ clock: (AnnotationClocks) -> Date
        ) -> (source: ClipboardItem, clock: Date) {
            var best = (source: winner, clock: effectiveClock(of: winner, clock))
            for item in copies {
                let candidate = effectiveClock(of: item, clock)
                if candidate > best.clock
                    || (candidate == best.clock && item.modifiedAt > best.source.modifiedAt) {
                    best = (item, candidate)
                }
            }
            return best
        }

        let pinned = latest(\.pinnedAt)
        let bookmarked = latest(\.bookmarkedAt)
        let tags = latest(\.tagsAt)

        var merged = withDerivedFields(winner, from: copies)
        merged.isPinned = pinned.source.isPinned
        merged.isBookmarked = bookmarked.source.isBookmarked
        merged.tags = tags.source.tags
        merged.timestamp = copies.map(\.timestamp).max() ?? winner.timestamp
        if clocked {
            merged.annotationClocks = AnnotationClocks(
                pinnedAt: pinned.clock, bookmarkedAt: bookmarked.clock, tagsAt: tags.clock
            )
        }
        if !hasSameSyncedFields(merged, as: winner) {
            merged.modifiedAt = (copies.map(\.modifiedAt).max() ?? winner.modifiedAt)
                .addingTimeInterval(mergeBumpInterval)
        }
        return merged
    }

    private static func effectiveClock(
        of item: ClipboardItem, _ clock: (AnnotationClocks) -> Date
    ) -> Date {
        clock(item.annotationClocks ?? AnnotationClocks(allAt: item.modifiedAt))
    }

    /// The fields sync uploads that the per-field rules can change.
    private static func hasSameSyncedFields(_ lhs: ClipboardItem, as rhs: ClipboardItem) -> Bool {
        lhs.isPinned == rhs.isPinned
            && lhs.isBookmarked == rhs.isBookmarked
            && lhs.tags == rhs.tags
            && lhs.timestamp == rhs.timestamp
            && lhs.annotationClocks == rhs.annotationClocks
    }

    /// Fields that follow their own rules rather than the whole-clip winner.
    private static func withDerivedFields(_ winner: ClipboardItem, from copies: [ClipboardItem]) -> ClipboardItem {
        var result = winner
        // AI enrichment is derived metadata (macOS-only) that rides `modifiedAt`, so a metadata-only
        // edit (pin/tag) from a device that never enriched would otherwise win the last-writer race
        // and erase it. Resolve AI fields on their own clock, independent of which side wins the item.
        let enriched = copies.dropFirst().reduce(copies[0], freshestEnrichment)
        result.aiTags = enriched.aiTags
        result.aiTitle = enriched.aiTitle
        result.aiEnrichedAt = enriched.aiEnrichedAt
        // richFilename references a local rich archive that sync never transports, so there is
        // no clock to compare and losing the last-writer race must not let the cleanup pass
        // delete it: carry it across from the losing side.
        if result.richFilename == nil {
            result.richFilename = copies.lazy.compactMap(\.richFilename).first
        }
        return result
    }

    private static func orderedByWriteClock(
        _ lhs: ClipboardItem, _ rhs: ClipboardItem
    ) -> (winner: ClipboardItem, loser: ClipboardItem) {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? (lhs, rhs) : (rhs, lhs)
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? (lhs, rhs) : (rhs, lhs)
        }
        return lhs.id.uuidString >= rhs.id.uuidString ? (lhs, rhs) : (rhs, lhs)
    }

    /// The side whose enrichment ran most recently (an un-enriched side, `aiEnrichedAt == nil`,
    /// always loses to an enriched one). When neither ran, the fields are empty on both.
    private static func freshestEnrichment(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> ClipboardItem {
        switch (lhs.aiEnrichedAt, rhs.aiEnrichedAt) {
        case let (l?, r?): return l >= r ? lhs : rhs
        case (.some, nil): return lhs
        case (nil, .some): return rhs
        case (nil, nil): return lhs
        }
    }

    private static func newestFirst(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        lhs.timestamp != rhs.timestamp
            ? lhs.timestamp > rhs.timestamp
            : lhs.id.uuidString > rhs.id.uuidString
    }
}
