import SwiftUI

struct ShareConfirmationView: View {
    enum Outcome: Equatable {
        case saved(excerpt: String)
        /// Some of several shared items were saved. `reason` names the items that were not.
        case partial(saved: Int, total: Int, reason: String?)
        case failed(reason: String? = nil)

        var glyph: String {
            switch self {
            case .saved: return "checkmark.circle.fill"
            case .partial, .failed: return "exclamationmark.triangle.fill"
            }
        }

        var headline: String {
            switch self {
            case .saved: return "Saved to Yank"
            case let .partial(saved, total, _): return "Saved \(saved) of \(total)"
            case .failed: return "Couldn't save"
            }
        }

        /// A card that reports a problem stays until the user dismisses it.
        var staysUntilDismissed: Bool {
            switch self {
            case .saved: return false
            case .partial, .failed: return true
            }
        }
    }

    let outcome: Outcome
    /// Called by the Done button of a card that stays until dismissed.
    var onDone: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @AccessibilityFocusState private var doneHasFocus: Bool

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: outcome.glyph)
                .font(.system(size: IOSMetric.unlockIconSize, weight: .semibold))
                .foregroundStyle(glyphStyle)
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(appeared ? 1 : 0.7)
                .accessibilityHidden(true)

            if outcome.staysUntilDismissed {
                messageColumn
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel)
                doneButton
            } else {
                messageColumn
            }

            YankWordmark(size: IOSType.wordmark)
                .opacity(0.7)
                .accessibilityHidden(true)
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
        // A card with a button keeps its children separate so Done can take focus; the success
        // card has nothing to act on and reads as one element.
        .accessibilityElement(children: outcome.staysUntilDismissed ? .contain : .combine)
        .modifier(SuccessAccessibilityLabel(label: outcome.staysUntilDismissed ? nil : accessibilityLabel))
        .onAppear { withAnimation(IOSMotion.present(reduceMotion)) { appeared = true } }
    }

    private var messageColumn: some View {
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

            if let reason = failureReason {
                Text(reason)
                    .font(.yank(.footnote))
                    .foregroundStyle(Color.yankDanger)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var doneButton: some View {
        Button {
            onDone?()
        } label: {
            Text("Done")
                .frame(maxWidth: .infinity, minHeight: ControlTarget.touch)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityFocused($doneHasFocus)
        .task { doneHasFocus = true }
    }

    private var failureReason: String? {
        switch outcome {
        case let .failed(reason), let .partial(_, _, reason): return reason
        case .saved: return nil
        }
    }

    private var glyphStyle: AnyShapeStyle {
        switch outcome {
        case .failed, .partial: return AnyShapeStyle(Color.yankDanger)
        case .saved: return AnyShapeStyle(.tint)
        }
    }

    private var accessibilityLabel: String {
        switch outcome {
        case let .saved(excerpt) where !excerpt.isEmpty: return "Saved to Yank. \(excerpt)"
        case .saved: return "Saved to Yank"
        case let .partial(saved, total, reason): return Self.partialAnnouncement(saved: saved, total: total, reason: reason)
        case let .failed(reason?): return "Couldn't save to Yank. \(reason)"
        case .failed: return "Couldn't save to Yank"
        }
    }

    /// What VoiceOver reads for a partly saved share, also used for the spoken announcement.
    static func partialAnnouncement(saved: Int, total: Int, reason: String?) -> String {
        let headline = "Saved \(saved) of \(total)"
        guard let reason else { return headline }
        return "\(headline). \(reason)"
    }
}

/// Applies one label to the whole success card; the other cards label their message column.
private struct SuccessAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }
}
