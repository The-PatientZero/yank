import SwiftUI

// History card section — retention tiers, auto-delete window, and the min-capture stepper.
extension SettingsView {
    var historySection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            adaptiveGrid(minimum: 112) {
                ForEach(HistoryLimit.allCases, id: \.self) { tier in tierButton(tier) }
            }
            Text("How many clips Yank keeps. \(SyncCopy.historyLimitScope(syncEnabled: manager.syncEnabled)) Pinned and bookmarked clips are always safe.")
                .font(.system(size: TypeScale.micro))
                .foregroundColor(.yankTextTertiary)

            Divider().overlay(Color.yankHairline)

            settingRowControl("Auto-delete after", "Older unprotected clips are removed.") {
                Picker("Auto-delete after", selection: Binding(
                    get: { manager.retentionDays },
                    set: { manager.retentionDays = $0; manager.save() })) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
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
    }

    func tierButton(_ tier: HistoryLimit) -> some View {
        let selected = manager.historyLimit == tier
        return Button(action: { selectHistoryLimit(tier) }) {
            // Tier carries its own filled-radio glyph as the non-colour cue, so it opts
            // out of the shared corner checkmark to avoid two redundant checkmarks.
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

    /// Same shared rule the iOS picker uses, so both platforms warn on exactly the cases that
    /// would actually delete something.
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

    var retentionAccessibilityValue: String {
        manager.retentionDays == 0 ? "Never" : "\(manager.retentionDays) days"
    }

    var minCaptureLengthAccessibilityValue: String {
        manager.minCaptureLength == 0 ? "Off" : "\(manager.minCaptureLength) characters"
    }

    func historyLimitAccessibilityHint(for tier: HistoryLimit, selected: Bool) -> String {
        if selected {
            return "Current history limit. Pinned and bookmarked clips are always safe."
        }
        if case .confirm = HistoryLimitChange.requested(
            tier,
            current: manager.historyLimit,
            items: store?.items
        ) {
            return "Asks before deleting older unprotected clips to reduce the limit."
        }
        return "Sets the history limit. Pinned and bookmarked clips are always safe."
    }
}
