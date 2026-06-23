import SwiftUI

struct CopyConfirmationCapsule: View {
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
