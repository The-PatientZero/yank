import SwiftUI

struct CopyConfirmationCapsule: View {
    /// How long the capsule stays up after a copy, in the history window and the Quick Picker.
    static let displayDuration: Duration = .milliseconds(1_400)

    var body: some View {
        HStack(spacing: 0) {
            Text("Copied").foregroundStyle(.primary)
            Text(".").foregroundStyle(.tint)
        }
        .font(.system(size: TypeScale.body, weight: .semibold, design: .serif))
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Color.yankRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityHidden(true)
    }
}
