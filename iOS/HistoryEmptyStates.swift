import SwiftUI

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
            Text("Your clipboard, on every device.")
                .font(.yank(.subheadline))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Space.lg) {
                OnboardingCaptureRow(
                    systemImage: "keyboard",
                    title: "Keyboard Extension",
                    description: "Enable the Yank keyboard under Settings → General → Keyboard → Keyboards to paste clips anywhere."
                )
                OnboardingCaptureRow(
                    systemImage: "square.and.arrow.up",
                    title: "Share Sheet",
                    description: "Share text or images from any app directly into Yank."
                )
                OnboardingCaptureRow(
                    systemImage: "bolt.circle",
                    title: "Action Button",
                    description: "Assign the Action Button on supported iPhone models to capture clips instantly."
                )
            }
            .frame(maxWidth: 360)
            .padding(.top, Space.sm)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "keyboard")
            }
            .buttonStyle(.borderedProminent)
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
