import SwiftUI

/// A waiting clip paired with the history item it stands for.
struct WaitingClipEntry: Identifiable {
    let clip: SyncWaitingClip
    let item: ClipboardItem

    var id: UUID { clip.id }
}

extension ClipStore {
    /// The waiting clips that still exist and are not waiting out a delete, so a delete leaves the
    /// list at once and an undo brings the clip back.
    var visibleWaitingClips: [WaitingClipEntry] {
        guard !waitingClips.isEmpty else { return [] }
        let visible = PendingDeletePolicy.visibleItems(items, pending: pendingDeletion)
        let itemsByID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return waitingClips.compactMap { clip in
            itemsByID[clip.id].map { WaitingClipEntry(clip: clip, item: $0) }
        }
    }
}

/// The clips this iPhone cannot upload as they are, with the two ways out: keep a clip on this
/// iPhone or delete it. Delete has the usual undo window; the commit timer lives in the history
/// screen underneath.
struct WaitingClipsView: View {
    var store: ClipStore
    var onKeepLocalOnly: (([UUID]) -> Void)?

    var body: some View {
        List {
            Section {
                ForEach(store.visibleWaitingClips) { entry in
                    row(entry)
                }
            } header: {
                Text(SyncCopy.waitingListHeading)
            }
            if let pending = store.pendingDeletion, hidesWaitingClip(pending) {
                Section {
                    HStack {
                        Text(PendingDeletePolicy.deletedMessage(count: pending.items.count))
                            .font(.yank(.subheadline))
                        Spacer()
                        Button("Undo") { store.undoPendingDelete() }
                    }
                }
            }
        }
        .navigationTitle(SyncCopy.waitingCount(store.visibleWaitingClips.count))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: WaitingClipEntry) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(entry.item.previewText)
                .font(.yank(.subheadline))
                .lineLimit(2)
            Text(SyncCopy.waitingReason(entry.clip.reason))
                .font(.yank(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xxs)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(SyncCopy.deleteWaitingClip, role: .destructive) { store.delete(entry.item) }
            Button(SyncCopy.keepOnDevice) { onKeepLocalOnly?([entry.id]) }
                .tint(.accentColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: SyncCopy.keepOnDevice) { onKeepLocalOnly?([entry.id]) }
        .accessibilityAction(named: SyncCopy.deleteWaitingClip) { store.delete(entry.item) }
    }

    private func hidesWaitingClip(_ pending: PendingDeletion) -> Bool {
        let waitingIDs = Set(store.waitingClips.map(\.id))
        return pending.items.contains { waitingIDs.contains($0.id) }
    }
}
