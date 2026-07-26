import SwiftUI

struct HistorySearchModifier: ViewModifier {
    @Binding var query: String
    var isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $query, prompt: "Search · #tag · @app")
        } else {
            content
        }
    }
}

extension View {
    func clipAccessibility(label: String, isSelected: Bool, action: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(action)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

struct CaptureSetupRow: View {
    let systemImage: String
    let title: String
    let description: String
    let isConfirmed: Bool
    let onToggleConfirmation: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: systemImage)
                .font(.yank(.title3))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(.yank(.subheadline, weight: .semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(.yank(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onToggleConfirmation) {
                    Label(
                        isConfirmed ? "Confirmed" : "Mark as Set Up",
                        systemImage: isConfirmed ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.yank(.caption, weight: .semibold))
                    .foregroundStyle(isConfirmed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(minHeight: ControlTarget.touch, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, Space.xxs)
                .accessibilityHint(isConfirmed ? "Marks this method as not confirmed" : "Marks this method as confirmed")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .contain)
    }
}
