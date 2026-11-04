import SwiftUI

extension SettingsView {
    var syncDescription: String {
        guard let store, case .localOnly(.notProvisioned) = store.syncStatus else {
            return SyncCopy.sectionDescription
        }
        return SyncCopy.localOnlySectionDescription
    }

    var syncSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            toggleRow(
                "iCloud Sync",
                SyncCopy.optInDescription,
                isOn: Binding(
                    get: { manager.syncEnabled },
                    set: { manager.setSyncEnabled($0) }))

            Text(syncDescription)
                .font(.system(size: TypeScale.body))
                .foregroundColor(.secondary)

            if let store {
                syncStatusRow(store.syncStatus, failureKind: store.syncFailureKind, clipsReceived: store.syncClipsReceived)
                syncActionRow(store.syncStatus, failureKind: store.syncFailureKind)
                waitingClipsSection(store)
                if case .localOnly = store.syncStatus {} else if let encryption = store.encryptionStatus {
                    encryptionStatusRow(encryption)
                }
            }
        }
    }

    func encryptionStatusRow(_ status: SyncEncryptionStatus) -> some View {
        let isWarning: Bool
        let symbol: String
        switch status {
        case .complete:
            isWarning = false
            symbol = "lock.icloud"
        case .olderDeviceSeen:
            isWarning = true
            symbol = "exclamationmark.icloud"
        case .finishing, .removingReadableCopies:
            isWarning = false
            symbol = "icloud.and.arrow.up"
        }
        return Label(SyncCopy.encryption(status), systemImage: symbol)
            .font(.system(size: TypeScale.caption))
            .foregroundColor(isWarning ? .yankDanger : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How often the "Synced 5 minutes ago" text is recomputed while Settings stays open.
    private static let syncClockInterval: TimeInterval = 30

    @ViewBuilder
    func syncStatusRow(_ status: SyncStatus, failureKind: SyncFailureKind?, clipsReceived: Int?) -> some View {
        switch status {
        case .localOnly(let reason):
            let text = switch reason {
            case .disabled: SyncCopy.disabled
            case .notProvisioned: SyncCopy.notProvisioned
            case .notAuthenticated: SyncCopy.signedOut
            }
            Label(text, systemImage: SyncCopy.Symbol.off)
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.yankTextTertiary)
        case .syncing:
            Label(clipsReceived.map(SyncCopy.syncingWithCount) ?? SyncCopy.syncingHeadline,
                  systemImage: SyncCopy.Symbol.syncing)
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.secondary)
        case .healthy(let lastSynced):
            TimelineView(.periodic(from: .now, by: Self.syncClockInterval)) { context in
                Label(SyncCopy.syncedText(lastSynced: lastSynced, now: context.date),
                      systemImage: SyncCopy.Symbol.synced)
                    .font(.system(size: TypeScale.caption))
                    .foregroundColor(.yankSuccess)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.xxs) {
                Label(SyncCopy.problemHeadline, systemImage: SyncCopy.Symbol.problem)
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .foregroundColor(.yankDanger)
                Text(message)
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(.yankTextTertiary)
                if let hint = SyncCopy.pathHint(for: failureKind) {
                    Text(hint)
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                }
            }
        }
    }

    /// "Sync now" whenever sync is on, plus the failure's own action next to the failure text.
    @ViewBuilder
    func syncActionRow(_ status: SyncStatus, failureKind: SyncFailureKind?) -> some View {
        if case .localOnly = status {} else {
            let isSyncing = status == .syncing
            let isFailed: Bool = { if case .failed = status { return true } else { return false } }()
            HStack(spacing: Space.sm) {
                if isFailed, SyncCopy.actions(for: failureKind).contains(.openSettings) {
                    Button(SyncCopy.title(for: .openSettings)) { SyncSystemSettings.openAppleIDPane() }
                        .buttonStyle(.bordered)
                }
                Button(isFailed ? SyncCopy.tryAgain : SyncCopy.syncNow) {
                    NotificationCenter.default.post(name: .yankSyncNowRequested, object: nil)
                }
                .buttonStyle(.bordered)
                .disabled(isSyncing)
            }
            .controlSize(.small)
        }
    }
}
