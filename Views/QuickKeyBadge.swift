import SwiftUI

struct QuickKeyBadge: View {
    let key: Int

    var body: some View {
        Text("⌘\(key)")
            .font(.system(size: TypeScale.micro, weight: .semibold, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityHidden(true)
    }
}
