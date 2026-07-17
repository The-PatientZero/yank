import SwiftUI

struct SettingsView: View {
    var store: ClipStore
    @Bindable var settings: IOSSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showClearConfirm = false

    @ScaledMetric(relativeTo: .caption) private var checkmarkSize: CGFloat = TypeScale.caption

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var syncSectionDescription: String {
        if case .localOnly(.notProvisioned) = store.syncStatus {
            return SyncCopy.localOnlySectionDescription
        }
        return SyncCopy.sectionDescription
    }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                syncSection
                getStartedSection
                historySection
                dataSection
                aboutSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { YankWordmark() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .animation(IOSMotion.state(reduceMotion), value: settings.themeID)
            .animation(IOSMotion.state(reduceMotion), value: settings.viewMode)
            .animation(IOSMotion.state(reduceMotion), value: settings.density)
        }
    }

    // MARK: - Sync section

    private var syncSection: some View {
        Section {
            Toggle(isOn: $settings.syncEnabled) {
                Label("iCloud Sync", systemImage: "icloud")
            }
            syncStatusRow
        } header: {
            Text("Sync")
        } footer: {
            Text("\(SyncCopy.optInDescription) \(syncSectionDescription)")
        }
    }

    @ViewBuilder private var syncStatusRow: some View {
        switch store.syncStatus {
        case .localOnly(let reason):
            switch reason {
            case .disabled:
                Label(SyncCopy.disabled, systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
                    .font(.yank(.subheadline))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(SyncCopy.disabled)
            case .notProvisioned:
                Label(SyncCopy.notProvisioned, systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
                    .font(.yank(.subheadline))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Sync unavailable. \(SyncCopy.notProvisioned)")
            case .notAuthenticated:
                HStack {
                    Label(SyncCopy.signedOut, systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .font(.yank(.subheadline))
                    Spacer()
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Settings")
                            .font(.yank(.subheadline))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signed out of iCloud. \(SyncCopy.signedOut)")
                .accessibilityHint("Opens Settings to sign in")
            }
        case .syncing:
            HStack(spacing: Space.md) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing…")
                    .foregroundStyle(.secondary)
                    .font(.yank(.subheadline))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Syncing your clips")
        case .healthy(let lastSynced):
            HStack {
                Label("Synced", systemImage: "checkmark.icloud.fill")
                    .foregroundStyle(.tint)
                    .font(.yank(.subheadline))
                Spacer()
                Text(lastSynced, style: .relative)
                    .font(.yank(.caption))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Synced")
            .accessibilityValue(Text(lastSynced, style: .relative))
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.xs) {
                Label("Sync failed", systemImage: "exclamationmark.icloud.fill")
                    .foregroundStyle(Color.yankDanger)
                    .font(.yank(.subheadline))
                Text(message)
                    .font(.yank(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync failed. \(message)")
        }
    }

    // MARK: - Get Started section

    private var getStartedSection: some View {
        Section {
            CapturePathRow(
                systemImage: "keyboard",
                title: "Keyboard Extension",
                description: "Use the Yank keyboard in any app to paste from your history.",
                actionLabel: "Open Settings",
                action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            )
            CapturePathRow(
                systemImage: "square.and.arrow.up",
                title: "Share Sheet",
                description: "Share text or images from any app directly into Yank.",
                actionLabel: nil,
                action: nil
            )
            CapturePathRow(
                systemImage: "bolt.circle",
                title: "Action Button",
                description: "On supported iPhone models, assign the Action Button to capture clips instantly.",
                actionLabel: nil,
                action: nil
            )
        } header: {
            Text("Get Started")
        } footer: {
            Text(SyncCopy.iCloudRequirement)
        }
    }

    // MARK: - Appearance section

    private var appearanceSection: some View {
        Section("Appearance") {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Accent").font(.yank(.subheadline))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(AppTheme.allCases) { theme in
                            Button { selectTheme(theme) } label: {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(Color.yankStrongSwatchBorder,
                                                                   lineWidth: settings.themeID == theme.id ? 2.5 : 0))
                                    .overlay(Image(systemName: "checkmark")
                                        .font(.system(size: checkmarkSize, weight: .bold))
                                        .foregroundStyle(theme.onAccent)
                                        .opacity(settings.themeID == theme.id ? 1 : 0))
                                    .scaleEffect(settings.themeID == theme.id && !reduceMotion ? 1.12 : 1)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(theme.label)
                            .accessibilityHint(settings.themeID == theme.id ? "Currently selected" : "Tap to select \(theme.label) accent")
                            .accessibilityAddTraits(settings.themeID == theme.id ? [.isButton, .isSelected] : .isButton)
                            .animation(IOSMotion.state(reduceMotion), value: settings.themeID)
                        }
                    }
                    .padding(.horizontal, Space.xxs)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Accent color")
            Picker("View", selection: $settings.viewMode) {
                ForEach(ClipViewMode.platformCases) { mode in Text(mode.label).tag(mode) }
            }
            .onChange(of: settings.viewMode) { _, newMode in
                coerceMacOnlyViewMode(newMode)
            }
            .onAppear { coerceMacOnlyViewMode(settings.viewMode) }
            Picker("Density", selection: $settings.density) {
                ForEach(ClipDensity.allCases) { density in Text(density.label).tag(density) }
            }
        }
    }

    private func coerceMacOnlyViewMode(_ mode: ClipViewMode) {
        if mode == .split { settings.viewMode = .list }
    }

    // MARK: - History section

    private var historySection: some View {
        Section {
            Picker("Keep", selection: $settings.historyLimit) {
                ForEach(HistoryLimit.allCases, id: \.self) { tier in Text(tier.label).tag(tier) }
            }
            Picker("Auto-delete", selection: $settings.retentionDays) {
                Text("Never").tag(0)
                Text("After 7 days").tag(7)
                Text("After 30 days").tag(30)
                Text("After 90 days").tag(90)
            }
            Toggle(isOn: Binding(
                get: { settings.spotlightIndexing },
                set: { newValue in
                    settings.spotlightIndexing = newValue
                    if newValue {
                        SpotlightIndexer.index(store.items)
                    } else {
                        SpotlightIndexer.clear()
                    }
                }
            )) {
                Label("Spotlight Indexing", systemImage: "magnifyingglass")
            }
        } header: {
            Text("History")
        } footer: {
            Text("Up to \(settings.historyLimit.subtitle) on this device. \(SyncCopy.perDeviceRetention) Pinned, bookmarked, and tagged clips are always kept.")
        }
        .onChange(of: settings.historyLimit) { _, _ in store.enforceRetentionAndLimit() }
        .onChange(of: settings.retentionDays) { _, _ in store.enforceRetentionAndLimit() }
    }

    // MARK: - Data section

    private var dataSection: some View {
        Section {
            Button(role: .destructive) { showClearConfirm = true } label: {
                Label("Clear History", systemImage: "trash")
            }
            .confirmationDialog("Clear all clips on this device?",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { store.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every clip from this device. With sync on, the clearance propagates to your other devices.")
            }
        } header: {
            Text("Data")
        } footer: {
            Text("\(store.items.count) clips on this device.")
        }
    }

    // MARK: - About section

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Link("Star on GitHub", destination: URL(string: "https://github.com/The-PatientZero/yank")!)
            Link("Privacy Policy", destination: YankLinks.privacyPolicy)
            Link("Report an Issue", destination: URL(string: "https://github.com/The-PatientZero/yank/issues/new")!)
            Link("Sponsor Yank", destination: URL(string: "https://github.com/sponsors/The-PatientZero")!)
            Text("Designed to disappear. Built to remember.")
                .font(.yank(.footnote))
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    private func selectTheme(_ theme: AppTheme) {
        IOSMotion.selectionFeedback()
        withAnimation(IOSMotion.state(reduceMotion)) { settings.themeID = theme.id }
    }
}

// MARK: - CapturePathRow

private struct CapturePathRow: View {
    let systemImage: String
    let title: String
    let description: String
    let actionLabel: String?
    let action: (() -> Void)?

    private var isActionable: Bool { actionLabel != nil && action != nil }

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: systemImage)
                .font(.yank(.title3))
                .foregroundStyle(isActionable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.yank(.subheadline, weight: .semibold))
                Text(description).font(.yank(.footnote)).foregroundStyle(.secondary)
                if let actionLabel, let action {
                    Button(actionLabel, action: action)
                        .font(.yank(.footnote))
                        .padding(.top, Space.xxs)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }
}
