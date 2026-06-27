import SwiftUI

struct ShareConfirmationView: View {
    enum Outcome: Equatable {
        case saved(excerpt: String)
        case failed(reason: String? = nil)

        var glyph: String {
            switch self {
            case .saved: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        var headline: String {
            switch self {
            case .saved: return "Saved to Yank"
            case .failed: return "Couldn't save"
            }
        }
    }

    let outcome: Outcome

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: outcome.glyph)
                .font(.system(size: IOSMetric.unlockIconSize, weight: .semibold))
                .foregroundStyle(glyphStyle)
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(appeared ? 1 : 0.7)
                .accessibilityHidden(true)

            VStack(spacing: Space.xs) {
                Text(outcome.headline)
                    .font(.yank(.title3, weight: .semibold))
                    .foregroundStyle(.primary)

                if case let .saved(excerpt) = outcome, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.yank(.subheadline))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                if case let .failed(reason) = outcome, let reason {
                    Text(reason)
                        .font(.yank(.footnote))
                        .foregroundStyle(Color.yankDanger)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }

            YankWordmark(size: IOSType.wordmark)
                .opacity(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl)
        .padding(.horizontal, Space.xxxl)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(Color.yankRaised)
                .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
        )
        .padding(Space.xxl)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { withAnimation(IOSMotion.present(reduceMotion)) { appeared = true } }
    }

    private var glyphStyle: AnyShapeStyle {
        switch outcome {
        case .failed: return AnyShapeStyle(Color.yankDanger)
        case .saved: return AnyShapeStyle(.tint)
        }
    }

    private var accessibilityLabel: String {
        switch outcome {
        case let .saved(excerpt) where !excerpt.isEmpty: return "Saved to Yank. \(excerpt)"
        case .saved: return "Saved to Yank"
        case let .failed(reason?): return "Couldn't save to Yank. \(reason)"
        case .failed: return "Couldn't save to Yank"
        }
    }
}
