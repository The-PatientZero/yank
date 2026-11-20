import SwiftUI

extension SettingsView {
    var historySection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            adaptiveGrid(minimum: 112) {
                ForEach(HistoryLimit.allCases, id: \.self) { tier in tierButton(tier) }
            }
            Text("How many clips Yank keeps. \(SyncCopy.historyLimitScope(syncEnabled: manager.syncEnabled)) \(SyncCopy.protectedClips)")
                .font(.system(size: TypeScale.micro))
                .foregroundColor(.yankTextTertiary)

            Divider().overlay(Color.yankHairline)

            settingRowControl("Auto-delete after", "Older unprotected clips are removed. \(SyncCopy.retentionCaption(syncEnabled: manager.syncEnabled))") {
                Picker("Auto-delete after", selection: Binding(
                    get: { manager.retentionMinutes },
                    set: { selectRetentionMinutes($0) })) {
                    ForEach(SettingsDefaults.retentionChoices, id: \.self) { minutes in
                        Text(SyncCopy.retentionLabel(minutes: minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 104)
                .accessibilityLabel("Auto-delete after")
                .accessibilityValue(retentionAccessibilityValue)
                .accessibilityHint("Choose when older unprotected clips are removed.")
            }
            settingRowControl("Ignore short copies", "Skip copies shorter than this length.") {
                Stepper(value: Binding(
                    get: { manager.minCaptureLength },
                    set: { manager.minCaptureLength = $0; manager.save() }), in: 0...500, step: 10) {
                    Text(manager.minCaptureLength == 0 ? "Off" : "\(manager.minCaptureLength) chars")
                        .font(.system(size: TypeScale.control))
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Ignore short copies")
                .accessibilityValue(minCaptureLengthAccessibilityValue)
                .accessibilityHint("Adjust the minimum copy length Yank captures.")
            }
        }
        .alert(
            SyncCopy.retentionReductionTitle(minutes: pendingRetention?.minutes ?? 0),
            isPresented: $showingRetentionAlert
        ) {
            Button("Cancel", role: .cancel) { pendingRetention = nil }
            Button("Delete Clips", role: .destructive) {
                if let pending = pendingRetention {
                    manager.setRetentionMinutes(pending.minutes)
                }
                pendingRetention = nil
            }
        } message: {
            if let pending = pendingRetention {
                Text(SyncCopy.retentionReduction(
                    minutes: pending.minutes,
                    deleting: pending.deleting,
                    syncEnabled: manager.syncEnabled
                ))
            }
        }
        .onChange(of: manager.retentionMinutes) {
            // An adopted remote window must not be overwritten by a late "Delete Clips".
            showingRetentionAlert = false
            pendingRetention = nil
        }
    }

    func tierButton(_ tier: HistoryLimit) -> some View {
        let selected = manager.historyLimit == tier
        return Button(action: { selectHistoryLimit(tier) }) {
            // Own filled-radio cue, so it skips the shared corner checkmark (avoids showing two).
            SelectionChip(isSelected: selected, showsCheckmarkCue: false) {
                VStack(alignment: .center, spacing: Space.xs) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected ? AppTheme.active.foreground : .secondary)
                        .font(.system(size: TypeScale.body))
                    Text(tier.label).font(.system(size: TypeScale.control, weight: .semibold))
                        .foregroundColor(selected ? .primary : .secondary)
                    Text(tier.subtitle).font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                }
                .padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tier.label) history limit")
        .accessibilityValue(selected ? "Selected, \(tier.subtitle)" : tier.subtitle)
        .accessibilityHint(historyLimitAccessibilityHint(for: tier, selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Mirrors the iOS picker's rule so both platforms warn on exactly the same
    /// changes that would actually delete something.
    func selectHistoryLimit(_ tier: HistoryLimit) {
        switch HistoryLimitChange.requested(
            tier,
            current: manager.historyLimit,
            items: store?.items
        ) {
        case .unchanged:
            break
        case .apply(let tier):
            manager.setHistoryLimit(tier)
        case .confirm(let tier):
            pendingTier = tier
            showingTrimAlert = true
        }
    }

    /// Mirrors the iOS picker's rule: a shortening that would delete, or that other devices may
    /// act on, asks first; anything else applies at once.
    func selectRetentionMinutes(_ minutes: Int) {
        switch RetentionChange.requested(
            minutes,
            current: manager.retentionMinutes,
            items: store?.items,
            syncEnabled: manager.syncEnabled,
            now: Date()
        ) {
        case .unchanged:
            break
        case .apply(let minutes):
            manager.setRetentionMinutes(minutes)
        case .confirm(let minutes, let deleting):
            pendingRetention = RetentionChange.Pending(minutes: minutes, deleting: deleting)
            showingRetentionAlert = true
        }
    }

    var retentionAccessibilityValue: String {
        SyncCopy.retentionLabel(minutes: manager.retentionMinutes)
    }

    var minCaptureLengthAccessibilityValue: String {
        manager.minCaptureLength == 0 ? "Off" : "\(manager.minCaptureLength) characters"
    }

    func historyLimitAccessibilityHint(for tier: HistoryLimit, selected: Bool) -> String {
        if selected {
            return "Current history limit. \(SyncCopy.protectedClips)"
        }
        if case .confirm = HistoryLimitChange.requested(
            tier,
            current: manager.historyLimit,
            items: store?.items
        ) {
            return "Asks before deleting older unprotected clips to reduce the limit."
        }
        return "Sets the history limit. \(SyncCopy.protectedClips)"
    }
}
