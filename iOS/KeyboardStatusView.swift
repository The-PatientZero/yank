import SwiftUI

struct KeyboardStatusView: View {
    enum Mode: Equatable {
        case empty
        case storageError
    }

    let mode: Mode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Space.md) {
            YankWordmark(size: IOSType.wordmark)

            Text(title)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(mode == .storageError ? Color.yankDanger : .primary)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.yank(.caption))
                .foregroundStyle(Color.yankTextTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .opacity(appeared ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { withAnimation(IOSMotion.quick(reduceMotion)) { appeared = true } }
    }

    private var title: String {
        switch mode {
        case .empty:           return "No text clips available"
        case .storageError:    return "Storage unavailable"
        }
    }

    private var subtitle: String {
        switch mode {
        case .empty:           return "Add or sync a text clip in Yank, then return here."
        case .storageError:    return "Yank couldn't read shared storage. Open the app and try again."
        }
    }

    private var accessibilityLabel: String {
        "\(title). \(subtitle)"
    }
}
