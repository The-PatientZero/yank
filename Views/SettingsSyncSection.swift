import SwiftUI

// Sync card section — the iCloud opt-in toggle plus the live status rows.
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
                syncStatusRow(store.syncStatus)
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

    @ViewBuilder
    func syncStatusRow(_ status: SyncStatus) -> some View {
        switch status {
        case .localOnly(let reason):
            let text = switch reason {
            case .disabled: SyncCopy.disabled
            case .notProvisioned: SyncCopy.notProvisioned
            case .notAuthenticated: SyncCopy.signedOut
            }
            Label(text, systemImage: "xmark.icloud")
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.yankTextTertiary)
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.secondary)
        case .healthy(let lastSynced):
            Label("Synced \(lastSynced.formatted(.relative(presentation: .named)))",
                  systemImage: "checkmark.icloud")
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.yankSuccess)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.xxs) {
                Label("Sync error", systemImage: "exclamationmark.icloud")
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .foregroundColor(.yankDanger)
                Text(message)
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(.yankTextTertiary)
            }
        }
    }
}
