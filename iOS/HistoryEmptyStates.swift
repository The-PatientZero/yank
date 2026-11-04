import SwiftUI

enum CaptureSetupCopy {
    static func completionActionTitle(confirmedMethodCount: Int) -> String {
        confirmedMethodCount == 0 ? "Skip for Now" : "Continue"
    }
}

/// Which parts of the first-run screen are shown. The set is fixed when the screen opens, so a
/// part never disappears because state moved underneath it (a clip arriving, a method confirmed).
struct FirstRunSections: OptionSet, Equatable, Identifiable {
    let rawValue: Int
    var id: Int { rawValue }

    static let clipboard = FirstRunSections(rawValue: 1 << 0)
    static let methods = FirstRunSections(rawValue: 1 << 1)
    static let sync = FirstRunSections(rawValue: 1 << 2)
}

/// The one first-run screen: clipboard access, the ways to save and paste, and the sync choice.
/// Every part saves its choice at once; only the finish button or a swipe closes the screen.
struct FirstRunSetupView: View {
    let sections: FirstRunSections
    var settings: IOSSettings
    /// Closes the screen. The flag says whether the user finished the capture-method part.
    let onFinish: (_ finishedSetup: Bool) -> Void

    @Environment(\.openURL) private var openURL

    /// Clips saved from Share or Shortcuts are written by the extensions; they upload on the next open.
    static let extensionSyncNote = "Clips saved from Share or Shortcuts reach iCloud the next time you open Yank."
    private static let notNowTitle = "Not Now"
    private static let shortcutsURL = "shortcuts://"
    private static let contentMaxWidth: CGFloat = 560
    private static let choiceIconWidth: CGFloat = 32

    private var showsMethods: Bool { sections.contains(.methods) }
    private var hasSeveralParts: Bool { sections.rawValue.nonzeroBitCount > 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                YankWordmark()
                    .accessibilityHidden(true)

                if hasSeveralParts {
                    Text("Set Up Yank")
                        .font(.yank(.largeTitle, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                }

                if sections.contains(.clipboard) { clipboardPart }
                if sections.contains(.methods) { methodsPart }
                if sections.contains(.sync) { syncPart }

                Button(action: finish) {
                    Text(finishTitle)
                        .frame(maxWidth: .infinity, minHeight: ControlTarget.touch)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("You can change all of this later in Settings.")
                    .font(.yank(.footnote))
                    .foregroundStyle(Color.yankTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xxl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.yankSurface)
        .presentationDragIndicator(.visible)
    }

    private var finishTitle: String {
        showsMethods
            ? CaptureSetupCopy.completionActionTitle(confirmedMethodCount: settings.confirmedCaptureMethods.count)
            : Self.notNowTitle
    }

    private func finish() {
        onFinish(showsMethods)
    }

    private func heading(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.yank(.title2, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.yank(.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Part 1: clipboard access

    private var clipboardPart: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            heading(
                "Clipboard access",
                detail: "Yank can check for new content when you open or return to the app. "
                    + "It never monitors the clipboard in the background."
            )
            VStack(spacing: 0) {
                ForEach(Array(IOSForegroundCaptureMode.decisionChoices.enumerated()), id: \.element) { index, mode in
                    clipboardChoice(mode)
                    if index < IOSForegroundCaptureMode.decisionChoices.count - 1 {
                        Divider().padding(.leading, Self.choiceIconWidth + Space.lg)
                    }
                }
            }
            if settings.storageUnavailable {
                Label(
                    "Clipboard choices are unavailable while shared storage is unavailable.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.yank(.footnote))
                .foregroundStyle(Color.yankDanger)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func clipboardChoice(_ mode: IOSForegroundCaptureMode) -> some View {
        let isSelected = settings.foregroundCaptureMode == mode
        return Button {
            settings.setForegroundCaptureMode(mode)
            if sections == .clipboard, settings.foregroundCaptureMode != .undecided {
                onFinish(false)
            }
        } label: {
            HStack(alignment: .top, spacing: Space.lg) {
                Image(systemName: mode.systemImage)
                    .font(.yank(.title2, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: Self.choiceIconWidth)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(mode.choiceTitle)
                        .font(.yank(.headline))
                        .foregroundStyle(.primary)
                    Text(mode.choiceDescription)
                        .font(.yank(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Space.sm)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.yank(.title3))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.yankTextTertiary))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Space.lg)
            .frame(minHeight: ControlTarget.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(settings.storageUnavailable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.choiceTitle)
        .accessibilityValue(mode.choiceDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    // MARK: - Part 2: save and paste

    private var methodsPart: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            heading(
                "Save and paste",
                detail: "Each method is independent. Confirm the ones you set up; you only need one to use Yank."
            )
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(IOSCaptureMethod.allCases) { method in
                    CaptureSetupRow(
                        systemImage: method.systemImage,
                        title: method.title,
                        description: method.description,
                        isConfirmed: settings.confirmedCaptureMethods.contains(method),
                        action: action(for: method)
                    ) {
                        settings.setCaptureMethod(
                            method,
                            confirmed: !settings.confirmedCaptureMethods.contains(method)
                        )
                    }
                }
            }
            Text("iOS does not report these system choices to Yank, so confirm a method after you configure it.")
                .font(.yank(.caption))
                .foregroundStyle(Color.yankTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func action(for method: IOSCaptureMethod) -> CaptureSetupAction? {
        switch method {
        case .keyboard:
            CaptureSetupAction(title: "Open Keyboard Settings", perform: AppSettingsLink.open)
        case .shortcut:
            CaptureSetupAction(title: "Open Shortcuts") {
                if let url = URL(string: Self.shortcutsURL) { openURL(url) }
            }
        case .shareSheet:
            nil
        }
    }

    // MARK: - Part 3: iCloud Sync

    private var syncPart: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            heading("iCloud Sync")
            Toggle(isOn: Binding(
                get: { settings.syncEnabled },
                set: { settings.syncEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Turn on iCloud Sync")
                        .font(.yank(.headline))
                    Text("\(SyncCopy.welcomeSyncDescription) \(Self.extensionSyncNote)")
                        .font(.yank(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: ControlTarget.touch)
            .disabled(settings.storageUnavailable)
        }
    }
}

extension HistoryView {
    var loadingState: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("Loading clips")
    }

    var syncingState: some View {
        EmptyStateView(glyphOpacity: 0.85) {
            YankWordmark(size: wordmarkSize)
            HStack(spacing: Space.md) {
                ProgressView()
                Text("Syncing your clips…")
                    .font(.yank(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Text(store.syncClipsReceived.map(SyncCopy.receivedSoFar) ?? "Pulling your history from iCloud.")
                .font(.yank(.footnote))
                .foregroundStyle(Color.yankTextTertiary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing your clips from iCloud")
        .accessibilityValue(store.syncClipsReceived.map(SyncCopy.receivedCount) ?? "")
    }

    func syncFailedState(message: String) -> some View {
        EmptyStateView(glyphOpacity: 0.85) {
            YankWordmark(size: wordmarkSize)
            Text("Sync could not start")
                .font(.yank(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.yank(.footnote))
                .foregroundStyle(Color.yankTextTertiary)
                .multilineTextAlignment(.center)
            if let onRetrySync {
                Button {
                    Task { await onRetrySync() }
                } label: {
                    Label("Retry Sync", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, Space.xs)
            }
        }
        .accessibilityElement(children: .contain)
    }

    var readyEmptyState: some View {
        EmptyStateView(glyphOpacity: 0.85) {
            YankWordmark(size: wordmarkSize)
            Text("Ready for your first clip")
                .font(.yank(.title3, weight: .semibold))
            Text("Share something to Yank or run Save Clipboard. The keyboard makes saved clips available in any app.")
                .font(.yank(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let onReviewCaptureMethods {
                Button("Review Capture Methods", action: onReviewCaptureMethods)
                    .buttonStyle(.bordered)
                    .padding(.top, Space.xs)
            }
        }
    }

    var noMatchesState: some View {
        EmptyStateView {
            Text("No matches").font(.yank(.title3, weight: .semibold))
            Text("Try a different search, or clear the filter.")
                .font(.yank(.subheadline))
                .foregroundStyle(.secondary)
        }
    }

    var pendingDeleteState: some View {
        EmptyStateView {
            Text("Clips deleted").font(.yank(.title3, weight: .semibold))
            Text("Undo is available for a moment.")
                .font(.yank(.subheadline))
                .foregroundStyle(.secondary)
        }
    }
}

private extension IOSForegroundCaptureMode {
    var systemImage: String {
        switch self {
        case .undecided: "questionmark.circle"
        case .automatic: "arrow.trianglehead.2.clockwise.rotate.90"
        case .explicitOnly: "hand.tap"
        }
    }
}

private extension IOSCaptureMethod {
    var systemImage: String {
        switch self {
        case .keyboard: "keyboard"
        case .shareSheet: "square.and.arrow.up"
        case .shortcut: "bolt.circle"
        }
    }

    var title: String {
        switch self {
        case .keyboard: "Keyboard Extension"
        case .shareSheet: "Share Sheet"
        case .shortcut: "Save Clipboard Shortcut"
        }
    }

    var description: String {
        switch self {
        case .keyboard:
            "Pastes clips you already saved, in any app. It never saves new clips. Tap Keyboards, then turn on Yank."
        case .shareSheet:
            "Saves text, links, or images from another app. In any app, tap Share, scroll to More, then turn on Yank."
        case .shortcut:
            "Find Save Clipboard under Yank. To run it from Back Tap or the Action Button, set that up in iOS Settings under Accessibility, Touch, Back Tap, or Action Button."
        }
    }
}
