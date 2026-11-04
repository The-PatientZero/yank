import SwiftUI

// Clips this Mac cannot upload: keep one on this Mac or delete it.
extension SettingsView {
    @ViewBuilder
    func waitingClipsSection(_ store: ClipboardStore) -> some View {
        let waiting = store.visibleWaitingClips
        if !waiting.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(SyncCopy.waitingListHeading)
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                    ForEach(waiting) { entry in
                        waitingClipRow(entry)
                    }
                    if waiting.count > 1 {
                        Button(SyncCopy.keepAllOnDevice) { keepOnThisDevice(waiting.map(\.id)) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.top, Space.xs)
            } label: {
                Label(SyncCopy.waitingCount(waiting.count), systemImage: SyncCopy.Symbol.problem)
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .foregroundColor(.yankDanger)
            }
        }
        if let pending = store.pendingDeletion, pendingDeleteHidesWaitingClip(pending, in: store) {
            HStack(spacing: Space.sm) {
                Text(PendingDeletePolicy.deletedMessage(count: pending.items.count))
                    .font(.system(size: TypeScale.caption))
                    .foregroundColor(.secondary)
                Button("Undo") { onUndoDelete?() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func pendingDeleteHidesWaitingClip(_ pending: PendingDeletion, in store: ClipboardStore) -> Bool {
        let waitingIDs = Set(store.waitingClips.map(\.id))
        return pending.items.contains { waitingIDs.contains($0.id) }
    }

    private func waitingClipRow(_ entry: WaitingClipEntry) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(entry.item.previewText)
                    .font(.system(size: TypeScale.caption))
                    .lineLimit(2)
                Text(SyncCopy.waitingReason(entry.clip.reason))
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(.yankTextTertiary)
            }
            Spacer(minLength: Space.md)
            Button(SyncCopy.keepOnDevice) { keepOnThisDevice([entry.id]) }
                .buttonStyle(.bordered)
            Button(SyncCopy.deleteWaitingClip, role: .destructive) { onDeleteClip?(entry.item) }
                .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    private func keepOnThisDevice(_ clipIDs: [UUID]) {
        NotificationCenter.default.post(
            name: .yankKeepClipsLocalRequested,
            object: nil,
            userInfo: [SyncNotificationKey.clipIDs: clipIDs]
        )
    }
}
