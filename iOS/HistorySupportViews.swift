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

struct OnboardingCaptureRow: View {
    let systemImage: String
    let title: String
    let description: String

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}
