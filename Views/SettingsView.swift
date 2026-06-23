import SwiftUI
import UniformTypeIdentifiers

private enum SettingsChipMetrics {
    static let modeTile = CGSize(width: 64, height: 48)
    static let densityChip = CGSize(width: 72, height: 30)
    static let accentSwatch: CGFloat = 28
    static let topBarTitleBalance: CGFloat = 64
}

/// Settings — a single scrolling column of grouped cards, shown as a screen inside
/// the main window (not a separate window). `onBack` returns to history.
struct SettingsView: View {
    var onBack: (() -> Void)? = nil
    var store: ClipboardStore? = nil
    var axPermission: AccessibilityPermission? = nil
    var appStatus: AppStatus? = nil

    private let manager = SettingsManager.shared
    @State private var isRecording = false
    @State private var showingTrimAlert = false
    @State private var pendingTier: HistoryLimit?
    @State private var shortcutConflict: String?
    @State private var launchAtLoginError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsHotkeyFailure: Bool {
        appStatus?.hotkeyRegistrationFailed == true
    }

    private var syncDescription: String {
        guard let store, case .localOnly(.notProvisioned) = store.syncStatus else {
            return SyncCopy.sectionDescription
        }
        return SyncCopy.localOnlySectionDescription
    }

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
                    manager.historyLimit = tier
                    saveHistoryLimit()
                }
            }
        } message: {
            Text("This will permanently delete your oldest unbookmarked items to fit the new size. This action cannot be undone.")
        }
        .background(KeyRecorder(isRecording: $isRecording, onRecord: { keyCode, modifiers in
            manager.hotkeyKeyCode = keyCode
            manager.hotkeyModifiers = modifiers
            saveHotkey()
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

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    Text(manager.hotkeyModifiers.displayString)
                        .font(.system(size: TypeScale.input, weight: .medium, design: .monospaced))
                    Text(keyCodeNames[manager.hotkeyKeyCode] ?? "?")
                        .font(.system(size: TypeScale.input, weight: .medium, design: .monospaced))
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(RoundedRectangle(cornerRadius: Radius.md)
                    .fill(isRecording ? AppTheme.active.selectionFill : Color.yankSurface))
                .overlay(RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(isRecording ? AppTheme.active.foreground : Color.yankHairline,
                            lineWidth: isRecording ? Stroke.focusRing : Hairline.width))
                .scaleEffect(isRecording && !reduceMotion ? 1.015 : 1)
                .animation(YankMotion.state(reduceMotion), value: isRecording)
                .accessibilityLabel("Current shortcut")
                .accessibilityValue(shortcutAccessibilityValue)

                Button(action: {
                    isRecording.toggle()
                    // Reset the conflict whether we're arming a fresh capture or cancelling.
                    shortcutConflict = nil
                }) {
                    Text(isRecording ? "Cancel" : "Change")
                        .font(.system(size: TypeScale.control, weight: .medium))
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            Text(shortcutHelperText)
                .font(.system(size: TypeScale.micro))
                .foregroundColor(shortcutConflict != nil ? .yankDanger
                                 : (isRecording ? AppTheme.active.foreground : .yankTextTertiary))

            if showsHotkeyFailure {
                Label("Shortcut registration failed — may conflict with another app.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(.yankDanger)
            }

            adaptiveGrid(minimum: 64) {
                presetButton(label: "⇧⌘V", humanLabel: "Shift Command V",
                             mods: HotkeyModifiers(shift: true, command: true), keyCode: 9)
                presetButton(label: "⌥⌘V", humanLabel: "Option Command V",
                             mods: HotkeyModifiers(command: true, option: true), keyCode: 9)
                presetButton(label: "⌃⇧V", humanLabel: "Control Shift V",
                             mods: HotkeyModifiers(shift: true, control: true), keyCode: 9)
                presetButton(label: "⌘B", humanLabel: "Command B",
                             mods: HotkeyModifiers(command: true), keyCode: 11)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            adaptiveGrid(minimum: 112) {
                ForEach(HistoryLimit.allCases, id: \.self) { tier in tierButton(tier) }
            }
            Text("How many clips Yank keeps. Pinned and bookmarked clips are always safe.")
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

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            CaptureExclusionSection()
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Find clips in Spotlight",
                "Lets macOS search your clips system-wide. Off by default — clip history can contain passwords and tokens.",
                isOn: Binding(
                    get: { manager.spotlightIndexingEnabled },
                    set: { newValue in
                        manager.spotlightIndexingEnabled = newValue
                        manager.save()
                        NotificationCenter.default.post(name: .yankSpotlightIndexingChanged, object: nil)
                    }))
        }
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            toggleRow(
                "iCloud Sync",
                SyncCopy.optInDescription,
                isOn: Binding(
                    get: { manager.syncEnabled },
                    set: { newValue in
                        manager.syncEnabled = newValue
                        manager.save()
                        NotificationCenter.default.post(name: .yankSyncPreferenceChanged, object: nil)
                    }))

            Text(syncDescription)
                .font(.system(size: TypeScale.body))
                .foregroundColor(.secondary)

            if let store {
                syncStatusRow(store.syncStatus)
            }

            if let axPermission {
                axPermissionRow(axPermission)
            }
        }
    }

    @ViewBuilder
    private func syncStatusRow(_ status: SyncStatus) -> some View {
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

    @ViewBuilder
    private func axPermissionRow(_ axPermission: AccessibilityPermission) -> some View {
        if !axPermission.isTrusted {
            HStack(spacing: Space.sm) {
                Image(systemName: "lock.fill").foregroundColor(.yankDanger)
                    .font(.system(size: TypeScale.caption))
                VStack(alignment: .leading, spacing: 1) {
                    Text(AccessibilityPermission.Copy.accessNeeded)
                        .font(.system(size: TypeScale.caption, weight: .medium))
                        .foregroundColor(.yankDanger)
                    Button(AccessibilityPermission.Copy.openSettings) {
                        axPermission.openSettingsAndAwaitGrant()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(AppTheme.active.foreground)
                }
            }
        }
    }

    private func quickPickerFieldAccessRow(_ axPermission: AccessibilityPermission) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "scope")
                .font(.system(size: TypeScale.caption))
                .foregroundColor(.yankDanger)
            VStack(alignment: .leading, spacing: 1) {
                Text("Accessibility needed to follow the focused field")
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .foregroundColor(.yankDanger)
                Button(AccessibilityPermission.Copy.openSettings) {
                    axPermission.openSettingsAndAwaitGrant()
                }
                .buttonStyle(.plain)
                .font(.system(size: TypeScale.micro))
                .foregroundColor(AppTheme.active.foreground)
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 0) {
                toggleRow("Launch at login", "Yank starts quietly when you log in.", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { newValue in
                        launchAtLoginError = manager.toggleLaunchAtLogin(newValue)
                    }))
                if let error = launchAtLoginError {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yankDanger)
                            .font(.system(size: TypeScale.caption))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(error)
                                .font(.system(size: TypeScale.micro))
                                .foregroundColor(.yankDanger)
                            Button("Open Login Items →") {
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
                                )
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: TypeScale.micro))
                            .foregroundColor(AppTheme.active.foreground)
                        }
                    }
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.sm)
                }
            }
            Divider().overlay(Color.yankHairline)
            VStack(alignment: .leading, spacing: Space.xs) {
                toggleRow("Show menu bar icon", "The global shortcut still works if it's hidden.", isOn: Binding(
                    get: { manager.showMenuBarIcon },
                    set: { newValue in
                        manager.showMenuBarIcon = newValue
                        manager.save()
                        NotificationCenter.default.post(name: .yankMenuBarVisibilityChanged, object: nil)
                    }))
                if !manager.showMenuBarIcon {
                    let shortcut = "\(manager.hotkeyModifiers.displayString)\(keyCodeNames[manager.hotkeyKeyCode] ?? "?")"
                    Text("Press \(shortcut) to open Yank, or reopen from Finder to access Settings.")
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(Color.yankHairline)
            field("Shortcut opens", manager.shortcutOpenTarget.blurb) {
                Picker("Shortcut opens", selection: Binding(
                    get: { manager.shortcutOpenTarget },
                    set: { newValue in
                        manager.shortcutOpenTarget = newValue
                        manager.save()
                    })) {
                    ForEach(ShortcutOpenTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 280, alignment: .leading)
                .accessibilityLabel("Shortcut opens")
                .accessibilityValue(manager.shortcutOpenTarget.label)
                .accessibilityHint(manager.shortcutOpenTarget.blurb)
            }
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Keep history window open",
                "Outside clicks leave it visible. Escape and paste still close it.",
                isOn: Binding(
                    get: { manager.keepHistoryWindowOpen },
                    set: { newValue in
                        manager.keepHistoryWindowOpen = newValue
                        manager.save()
                    }))
            Divider().overlay(Color.yankHairline)
            field("Open history at", manager.historyWindowPlacement.blurb) {
                Picker("Open history at", selection: Binding(
                    get: { manager.historyWindowPlacement },
                    set: { newValue in
                        manager.historyWindowPlacement = newValue
                        manager.save()
                    })) {
                    ForEach(HistoryWindowPlacement.allCases) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 340, alignment: .leading)
                .accessibilityLabel("Open history at")
                .accessibilityValue(manager.historyWindowPlacement.label)
                .accessibilityHint(manager.historyWindowPlacement.blurb)
            }
            Divider().overlay(Color.yankHairline)
            field("Open quick picker at", manager.quickPickerPlacement.blurb) {
                Picker("Open quick picker at", selection: Binding(
                    get: { manager.quickPickerPlacement },
                    set: { newValue in
                        manager.quickPickerPlacement = newValue
                        manager.save()
                    })) {
                    ForEach(QuickPickerPlacement.allCases) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 340, alignment: .leading)
                .accessibilityLabel("Open quick picker at")
                .accessibilityValue(manager.quickPickerPlacement.label)
                .accessibilityHint(manager.quickPickerPlacement.blurb)

                if manager.quickPickerPlacement == .focusedInput,
                   let axPermission,
                   !axPermission.isTrusted {
                    quickPickerFieldAccessRow(axPermission)
                }
            }
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Click to paste",
                "List, Grid, Masonry, and Gallery paste immediately. Split previews first.",
                isOn: Binding(
                    get: { manager.clickToPasteInQuickViews },
                    set: { newValue in
                        manager.clickToPasteInQuickViews = newValue
                        manager.save()
                    }))
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Haptic feedback",
                "A subtle tap on copy, paste, and pin. Needs a Force Touch trackpad.",
                isOn: Binding(
                    get: { manager.hapticFeedbackEnabled },
                    set: { newValue in
                        manager.hapticFeedbackEnabled = newValue
                        manager.save()
                        if newValue { Haptics.fire(.pin) }   // let the user feel it the moment they enable it
                    }))
            Divider().overlay(Color.yankHairline)
            soundEffectsSection
        }
    }

    private var soundEffectsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            toggleRow(
                "Sound effects",
                "A quiet cue on copy and paste.",
                isOn: Binding(
                    get: { manager.soundEffectsEnabled },
                    set: { newValue in
                        manager.soundEffectsEnabled = newValue
                        manager.save()
                        if newValue { Sounds.preview(manager.soundEffectChoice) }
                    }))
            soundChoiceRow
                .disabled(!manager.soundEffectsEnabled)
                .opacity(manager.soundEffectsEnabled ? 1 : 0.55)
        }
    }

    private var soundChoiceRow: some View {
        settingRowControl("Cue style", manager.soundEffectChoice.blurb) {
            HStack(spacing: Space.sm) {
                Picker("Cue style", selection: Binding(
                    get: { manager.soundEffectChoice },
                    set: { newValue in
                        manager.soundEffectChoice = newValue
                        manager.save()
                        if manager.soundEffectsEnabled { Sounds.preview(newValue) }
                    })) {
                    ForEach(SoundEffectChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 104)
                .accessibilityLabel("Cue style")
                .accessibilityValue(manager.soundEffectChoice.label)
                .accessibilityHint(manager.soundEffectChoice.blurb)

                IconButton(
                    systemName: "speaker.wave.2.fill",
                    label: "Preview copy sound",
                    help: "Preview \(manager.soundEffectChoice.label)",
                    tint: AppTheme.active.foreground,
                    size: TypeScale.control,
                    weight: .medium
                ) {
                    Sounds.preview(manager.soundEffectChoice)
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
    private func field<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
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

    private func adaptiveGrid<C: View>(minimum: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Space.sm)],
                  alignment: .leading,
                  spacing: Space.sm) {
            content()
        }
    }

    private func accentSwatch(_ theme: AppTheme) -> some View {
        Button { setAccent(theme) } label: {
            Circle()
                .fill(theme.color)
                .frame(width: SettingsChipMetrics.accentSwatch, height: SettingsChipMetrics.accentSwatch)
                .overlay(Circle().strokeBorder(Color.yankStrongSwatchBorder,
                                               lineWidth: manager.themeID == theme.id ? 2.5 : 0))
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: TypeScale.caption, weight: .bold))
                    .foregroundColor(theme.onAccent)
                    .opacity(manager.themeID == theme.id ? 0.95 : 0))
                .scaleEffect(manager.themeID == theme.id && !reduceMotion ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(theme.label)
        .accessibilityLabel("\(theme.label) accent")
        .accessibilityValue(manager.themeID == theme.id ? "Selected" : "Not selected")
        .accessibilityHint(manager.themeID == theme.id
            ? "Current accent color."
            : "Sets the accent color to \(theme.label).")
        .accessibilityAddTraits(manager.themeID == theme.id ? .isSelected : [])
        .animation(YankMotion.state(reduceMotion), value: manager.themeID)
    }

    private func modeChip(_ mode: ClipViewMode) -> some View {
        let selected = manager.viewMode == mode
        return Button {
            manager.viewMode = mode
            manager.save()
            NotificationCenter.default.post(name: .yankAppearanceChanged, object: nil)
        } label: {
            SelectionChip(isSelected: selected) {
                VStack(spacing: Space.xs) {
                    Image(systemName: mode.symbol).font(.system(size: TypeScale.body))
                    Text(mode.label).font(.system(size: TypeScale.micro, weight: .medium))
                }
                .frame(width: SettingsChipMetrics.modeTile.width, height: SettingsChipMetrics.modeTile.height)
            }
        }
        .buttonStyle(.plain)
        .help("\(mode.label) — \(mode.blurb)")
        .accessibilityLabel("\(mode.label) view")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected
            ? "Current view mode. \(mode.blurb)"
            : "Switches to \(mode.label) view. \(mode.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func densityChip(_ d: ClipDensity) -> some View {
        let selected = manager.density == d
        return Button {
            manager.density = d
            manager.save()
            NotificationCenter.default.post(name: .yankAppearanceChanged, object: nil)
        } label: {
            SelectionChip(isSelected: selected) {
                Text(d.label)
                    .font(.system(size: TypeScale.control, weight: .medium))
                    .frame(width: SettingsChipMetrics.densityChip.width, height: SettingsChipMetrics.densityChip.height)
            }
        }
        .buttonStyle(.plain)
        .help("\(d.label) — \(d.blurb)")
        .accessibilityLabel("\(d.label) density")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected
            ? "Current density. \(d.blurb)"
            : "Switches to \(d.label) density. \(d.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tierButton(_ tier: HistoryLimit) -> some View {
        let selected = manager.historyLimit == tier
        return Button(action: {
            if tier.rawValue < manager.historyLimit.rawValue {
                pendingTier = tier
                showingTrimAlert = true
            } else {
                manager.historyLimit = tier
                saveHistoryLimit()
            }
        }) {
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

    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        settingRowControl(title, subtitle) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
                .accessibilityHint(subtitle)
        }
    }

    /// Helper line under the shortcut field: the conflict reason wins, then the
    /// recording prompt, then the resting explanation.
    private var shortcutHelperText: String {
        if let conflict = shortcutConflict {
            return "\(conflict) is reserved by macOS. Try another shortcut."
        }
        return isRecording ? "Press your new shortcut…" : "The global shortcut opens Yank from any app."
    }

    private var shortcutAccessibilityValue: String {
        let combo = "\(manager.hotkeyModifiers.displayString)\(keyCodeNames[manager.hotkeyKeyCode] ?? "?")"
        if let conflict = shortcutConflict {
            return "\(combo). \(conflict) is reserved by macOS — try another shortcut."
        }
        return combo
    }

    private var retentionAccessibilityValue: String {
        manager.retentionDays == 0 ? "Never" : "\(manager.retentionDays) days"
    }

    private var minCaptureLengthAccessibilityValue: String {
        manager.minCaptureLength == 0 ? "Off" : "\(manager.minCaptureLength) characters"
    }

    private func historyLimitAccessibilityHint(for tier: HistoryLimit, selected: Bool) -> String {
        if selected {
            return "Current history limit. Pinned and bookmarked clips are always safe."
        }
        if tier.rawValue < manager.historyLimit.rawValue {
            return "Asks before deleting older unprotected clips to reduce the limit."
        }
        return "Sets the history limit. Pinned and bookmarked clips are always safe."
    }

    private func settingRowControl<C: View>(_ title: String, _ subtitle: String,
                                            @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center) {
            settingLabel(title, subtitle)
            Spacer()
            control()
        }
        .padding(.vertical, Space.xs)
    }

    private func setAccent(_ theme: AppTheme) {
        manager.themeID = theme.id
        manager.save()
        NotificationCenter.default.post(name: .yankThemeChanged, object: nil)
    }

    private func saveHotkey() {
        manager.save()
        NotificationCenter.default.post(name: .yankHotkeyChanged, object: nil)
    }

    /// Persist a history-limit change; `save()` re-injects the capture snapshot so the store
    /// trims to the new size (via `.yankCaptureSettingsChanged`).
    private func saveHistoryLimit() {
        manager.save()
    }

    private func presetButton(label: String, humanLabel: String, mods: HotkeyModifiers, keyCode: UInt16) -> some View {
        let isActive = manager.hotkeyModifiers == mods && manager.hotkeyKeyCode == keyCode
        return Button(action: {
            manager.hotkeyModifiers = mods
            manager.hotkeyKeyCode = keyCode
            saveHotkey()
        }) {
            Text(label)
                .font(.system(size: TypeScale.control, weight: .medium, design: .monospaced))
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(humanLabel) shortcut preset")
        .accessibilityValue(isActive ? "Current shortcut" : "")
        .accessibilityHint("Sets the global shortcut to \(humanLabel).")
    }
}

private extension HistoryWindowPlacement {
    var label: String {
        switch self {
        case .menuBarIcon: "Icon"
        case .lastPosition: "Last"
        case .center: "Center"
        case .topRight: "Top right"
        }
    }

    var blurb: String {
        switch self {
        case .menuBarIcon: "Attach it under the menu bar icon. Falls back to top right when the icon is hidden."
        case .lastPosition: "Reopen where you last moved or resized it."
        case .center: "Open in the center of the active screen."
        case .topRight: "Open near the menu bar on the active screen."
        }
    }
}

private extension QuickPickerPlacement {
    var label: String {
        switch self {
        case .focusedInput: "Field"
        case .menuBarIcon: "Icon"
        case .lastPosition: "Last"
        case .center: "Center"
        case .topRight: "Top right"
        }
    }

    var blurb: String {
        switch self {
        case .focusedInput: "Open beside the focused text field. Falls back to the menu-bar icon when access is unavailable."
        case .menuBarIcon: "Attach it under the menu bar icon. Falls back to top right when the icon is hidden."
        case .lastPosition: "Reopen where you last moved it."
        case .center: "Open in the center of the active screen."
        case .topRight: "Open near the menu bar on the active screen."
        }
    }
}

private extension ShortcutOpenTarget {
    var label: String {
        switch self {
        case .quickPicker: "Quick picker"
        case .fullHistory: "Full history"
        }
    }

    var blurb: String {
        switch self {
        case .quickPicker: "Use the compact chooser for fast paste decisions."
        case .fullHistory: "Open the full organizing window directly."
        }
    }
}

private extension SoundEffectChoice {
    var label: String {
        switch self {
        case .system: "System"
        case .tick: "Tick"
        case .click: "Click"
        case .select: "Select"
        }
    }

    var blurb: String {
        switch self {
        case .system: "The original macOS Tink and Pop."
        case .tick: "Fast and almost invisible."
        case .click: "Crisp, mechanical, and direct."
        case .select: "Rounded and neutral."
        }
    }
}
