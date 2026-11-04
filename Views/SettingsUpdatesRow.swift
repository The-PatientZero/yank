import SwiftUI

/// The "Updates" row in Settings → About: the current update status in a sentence and one button
/// for the next step. It uses the same update logic as the right-click panel, so a Mac with the
/// menu-bar icon hidden can still find and start an update from Settings.
struct SettingsUpdatesRow: View {
    @State private var state = UpdateService.shared.state

    private static let title = "Updates"

    var body: some View {
        let presentation = state.menuPresentation
        HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(Self.title).font(.system(size: TypeScale.control, weight: .semibold))
                Text(state.statusText)
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(.yankTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if presentation.isWorking {
                ProgressView().controlSize(.small)
            }
            Button(presentation.title) {
                if let action = presentation.action {
                    UpdateService.shared.handleMenuAction(action)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(presentation.action == nil)
            .accessibilityHint(presentation.accessibilityHint)
        }
        .padding(.vertical, Space.xs)
        .onAppear { state = UpdateService.shared.state }
        .onReceive(NotificationCenter.default.publisher(for: .yankUpdateStateChanged)) { _ in
            state = UpdateService.shared.state
        }
    }
}
