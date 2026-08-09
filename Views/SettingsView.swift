import SwiftUI
import UniformTypeIdentifiers

enum SettingsChipMetrics {
    static let modeTile = CGSize(width: 64, height: 48)
    static let densityChip = CGSize(width: 72, height: 30)
    static let accentSwatch: CGFloat = 28
    static let topBarTitleBalance: CGFloat = 64
}

/// Settings — a single scrolling column of grouped cards, shown as a screen inside
/// the main window (not a separate window). `onBack` returns to history.
///
/// The cards compose here; each section's controls live in a `Settings…Section.swift`
/// extension file (General, History, Privacy, Sync, Shortcut, Appearance). The shared
/// state and the reusable label/row helpers stay here so every section reads from one place.
struct SettingsView: View {
    var onBack: (() -> Void)? = nil
    var store: ClipboardStore? = nil
    var axPermission: AccessibilityPermission? = nil
    var appStatus: AppStatus? = nil

    var manager: SettingsManager = .shared
    @State var isRecording = false
    @State var showingTrimAlert = false
    @State var pendingTier: HistoryLimit?
    @State var shortcutConflict: String?
    @State var launchAtLoginError: String?
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    captureAndHistoryCard
                    syncAndShortcutCard
                    appearanceCard
                    aboutCard
                }
                .padding(Space.xxl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YankWindowBackground())
        .tint(AppTheme.active.foreground)
        .onExitCommand { onBack?() }
        .alert("Reduce History Limit?", isPresented: $showingTrimAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reduce & Delete", role: .destructive) {
                if let tier = pendingTier {
                    manager.setHistoryLimit(tier)
                }
            }
        } message: {
            Text(SyncCopy.historyLimitReduction(syncEnabled: manager.syncEnabled))
        }
        .background(KeyRecorder(isRecording: $isRecording, onRecord: { keyCode, modifiers in
            manager.setHotkey(keyCode: keyCode, modifiers: modifiers)
            shortcutConflict = nil
            isRecording = false
        }, onConflict: { combo in
            shortcutConflict = combo
        }, onCancel: {
            shortcutConflict = nil
            isRecording = false
        }))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Space.md) {
            Button { onBack?() } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.left").font(.system(size: TypeScale.body, weight: .semibold))
                    Text("History").font(.system(size: TypeScale.body))
                }
            }
            .buttonStyle(.plain)
            .help("Back to history (esc)")

            Spacer()

            HStack(spacing: 0) {
                Text("Settings").font(.system(size: TypeScale.title, weight: .semibold, design: .serif))
                Text(".").font(.system(size: TypeScale.title, weight: .semibold, design: .serif))
                    .foregroundColor(AppTheme.active.foreground)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Settings")

            Spacer()
            Color.clear.frame(width: SettingsChipMetrics.topBarTitleBalance, height: 0)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.lg)
        .overlay(Rectangle().frame(height: Hairline.width).foregroundColor(Color.yankHairline), alignment: .bottom)
    }

    // MARK: - Cards

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(title).yankSectionLabel()
            content()
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yankRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
    }

    private func subsectionLabel(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Divider().overlay(Color.yankHairline)
            Text(title).yankSectionLabel()
        }
    }

    private var captureAndHistoryCard: some View {
        card("Capture & History") {
            generalSection
            subsectionLabel("History")
            historySection
            subsectionLabel("Privacy")
            privacySection
        }
    }

    private var syncAndShortcutCard: some View {
        card("Sync & Shortcut") {
            syncSection
            subsectionLabel("Shortcut")
            shortcutSection
        }
    }

    private var appearanceCard: some View {
        card("Appearance") {
            field("Accent", "The colour Yank wears — the dot, selection, and focus.") {
                adaptiveGrid(minimum: 32) {
                    ForEach(AppTheme.allCases) { theme in accentSwatch(theme) }
                }
            }
            field("View", "How clips are laid out. \(manager.viewMode.blurb)") {
                adaptiveGrid(minimum: 64) {
                    ForEach(ClipViewMode.allCases) { mode in modeChip(mode) }
                }
            }
            field("Density", "How much breathing room each clip gets. \(manager.density.blurb)") {
                adaptiveGrid(minimum: 72) {
                    ForEach(ClipDensity.allCases) { d in densityChip(d) }
                }
            }
        }
    }

    private var aboutCard: some View {
        card("About") {
            HStack(spacing: Space.lg) {
                YankBrandMark(size: 48)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Designed to disappear. Built to remember.")
                        .font(.system(size: TypeScale.body, design: .serif))
                        .italic()
                        .foregroundColor(.secondary)
                    Text("Yank \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · by @The-PatientZero")
                        .font(.system(size: TypeScale.caption))
                        .foregroundColor(.yankTextTertiary)
                }
            }
            HStack(spacing: Space.lg) {
                Link("Star on GitHub", destination: URL(string: "https://github.com/The-PatientZero/yank")!)
                Link("Privacy Policy", destination: YankLinks.privacyPolicy)
                Link("Report an Issue", destination: URL(string: "https://github.com/The-PatientZero/yank/issues/new")!)
                Link("Sponsor Yank", destination: URL(string: "https://github.com/sponsors/The-PatientZero")!)
            }
            .font(.system(size: TypeScale.caption, weight: .medium))
        }
    }

    // MARK: - Pieces

    /// One label model across the whole screen: title, then its one-line explanation
    /// directly beneath it, then the control. `field` stacks the control under the
    /// caption (for grids/swatches); `settingRowControl` floats the control to the
    /// trailing edge (for a single toggle/picker) — but the "explanation lives right
    /// under the title" rule is now the same in both, so the eye learns it once.
    func field<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            settingLabel(title, subtitle)
            content()
        }
    }

    /// The shared title + caption pair used by every label model on this screen.
    private func settingLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.system(size: TypeScale.control, weight: .semibold))
            Text(subtitle).font(.system(size: TypeScale.micro)).foregroundColor(.yankTextTertiary)
        }
    }

    func adaptiveGrid<C: View>(minimum: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Space.sm)],
                  alignment: .leading,
                  spacing: Space.sm) {
            content()
        }
    }

    func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        settingRowControl(title, subtitle) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
                .accessibilityHint(subtitle)
        }
    }

    func settingRowControl<C: View>(_ title: String, _ subtitle: String,
                                    @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center) {
            settingLabel(title, subtitle)
            Spacer()
            control()
        }
        .padding(.vertical, Space.xs)
    }
}
