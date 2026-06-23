import SwiftUI

struct EmptyStateView<Content: View>: View {
    var glyphOpacity: Double = 0.5
    var animatesIn: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Space.lg) {
                    Image("BrandGlyph")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: IOSMetric.emptyIconSize, height: IOSMetric.emptyIconSize)
                        .foregroundStyle(.secondary)
                        .opacity(glyphOpacity)
                        .accessibilityHidden(true)
                    content()
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .padding(.horizontal, Space.xxxl)
                .padding(.top, Space.xxl)
                .padding(.bottom, ControlTarget.touch * 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.yankSurface)
        .opacity(appeared ? 1 : (animatesIn ? 0 : 1))
        .scaleEffect(appeared ? 1 : (animatesIn && !reduceMotion ? MotionScale.summon : 1))
        .onAppear {
            if animatesIn {
                withAnimation(IOSMotion.present(reduceMotion)) { appeared = true }
            } else {
                appeared = true
            }
        }
    }
}
