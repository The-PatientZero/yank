import SwiftUI

enum CaptureSetupCopy {
    static func completionActionTitle(confirmedMethodCount: Int) -> String {
        confirmedMethodCount == 0 ? "Skip for Now" : "Continue"
    }
}

struct ForegroundCaptureDecisionView: View {
    let onChoose: (IOSForegroundCaptureMode) -> Void
    let onNotNow: () -> Void
    let choicesDisabled: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    YankWordmark()
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Choose Clipboard Access")
                            .font(.yank(.largeTitle, weight: .bold))
                        Text(
                            "Yank can check for new content when you open or return to "
                                + "the app. It never monitors the clipboard in the background."
                        )
                        .font(.yank(.body))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(spacing: 0) {
                        ForEach(
                            Array(IOSForegroundCaptureMode.decisionChoices.enumerated()),
                            id: \.element
                        ) {
                            index,
                            mode in
                            Button {
                                onChoose(mode)
                            } label: {
                                HStack(alignment: .top, spacing: Space.lg) {
                                    Image(systemName: mode.systemImage)
                                        .font(.yank(.title2, weight: .medium))
                                        .foregroundStyle(.tint)
                                        .frame(width: 32)
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

                                    Image(systemName: "chevron.forward")
                                        .font(.yank(.subheadline, weight: .semibold))
                                        .foregroundStyle(Color.yankTextTertiary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, Space.lg)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(choicesDisabled)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(mode.choiceTitle)
                            .accessibilityValue(mode.choiceDescription)
                            .accessibilityHint("Selects this clipboard capture mode")

                            if index < IOSForegroundCaptureMode.decisionChoices.count - 1 {
                                Divider()
                                    .padding(.leading, 32 + Space.lg)
                            }
                        }
                    }

                    if choicesDisabled {
                        Label(
                            "Clipboard choices are unavailable while shared storage is unavailable.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.yank(.footnote))
                        .foregroundStyle(Color.yankDanger)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("You can change this later in Settings.")
                    .font(.yank(.footnote))
                    .foregroundStyle(Color.yankTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color.yankSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now", action: onNotNow)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

extension HistoryView {
    var syncingState: some View {
        EmptyStateView(glyphOpacity: 0.85) {
            YankWordmark(size: wordmarkSize)
            HStack(spacing: Space.md) {
                ProgressView()
                Text("Syncing your clips…")
                    .font(.yank(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Text("Pulling your history from iCloud.")
                .font(.yank(.footnote))
                .foregroundStyle(Color.yankTextTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing your clips from iCloud")
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

    var iCloudSignedOutState: some View {
        EmptyStateView(glyphOpacity: 0.85) {
            YankWordmark(size: wordmarkSize)
            Image(systemName: "icloud.slash")
                .font(.system(size: TypeScale.stat))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Sign in to iCloud to sync")
                .font(.yank(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(SyncCopy.signedOut)
                .font(.yank(.footnote))
                .foregroundStyle(Color.yankTextTertiary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.bordered)
            .padding(.top, Space.xs)
        }
        .accessibilityElement(children: .contain)
    }

    var onboardingState: some View {
        EmptyStateView(glyphOpacity: 0.85) {
            YankWordmark(size: wordmarkSize)
            Text("Choose how you capture")
                .font(.yank(.title3, weight: .semibold))
            Text("Each method is independent. Confirm the ones you set up; you only need one to use Yank.")
                .font(.yank(.footnote))
                .foregroundStyle(Color.yankTextTertiary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(IOSCaptureMethod.allCases) { method in
                    CaptureSetupRow(
                        systemImage: method.systemImage,
                        title: method.title,
                        description: method.description,
                        isConfirmed: settings.confirmedCaptureMethods.contains(method)
                    ) {
                        settings.setCaptureMethod(
                            method,
                            confirmed: !settings.confirmedCaptureMethods.contains(method)
                        )
                    }
                }
            }
            .frame(maxWidth: 360)
            .padding(.top, Space.sm)
            Button {
                settings.completeCaptureSetup()
            } label: {
                Text(
                    CaptureSetupCopy.completionActionTitle(
                        confirmedMethodCount: settings.confirmedCaptureMethods.count
                    )
                )
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, Space.xs)
            Text("iOS does not report these system choices to Yank, so confirm a method after you configure it.")
                .font(.yank(.caption))
                .foregroundStyle(Color.yankTextTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
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
            Button("Review Capture Methods") {
                settings.captureSetupCompleted = false
            }
            .buttonStyle(.bordered)
            .padding(.top, Space.xs)
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
            "Enable Yank under Settings → General → Keyboard → Keyboards to paste clips you already saved."
        case .shareSheet:
            "Add Yank to the Share Sheet to save text, links, or images from another app."
        case .shortcut:
            "Run Save Clipboard from Shortcuts, Siri, Back Tap, or the Action Button."
        }
    }
}
