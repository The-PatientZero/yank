import SwiftUI

struct KeyboardStatusView: View {
    enum Mode: Equatable {
        case needsFullAccess
        case empty
        case storageError
    }

    let mode: Mode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let fullAccessSteps = [
        "Open Settings", "General", "Keyboard", "Keyboards", "Yank", "Allow Full Access"
    ]

    var body: some View {
        VStack(spacing: Space.md) {
            YankWordmark(size: IOSType.wordmark)

            Text(title)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(mode == .storageError ? Color.yankDanger : .primary)
                .multilineTextAlignment(.center)

            if mode == .needsFullAccess {
                fullAccessGuide
            } else {
                Text(subtitle)
                    .font(.yank(.caption))
                    .foregroundStyle(Color.yankTextTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .opacity(appeared ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { withAnimation(IOSMotion.quick(reduceMotion)) { appeared = true } }
    }

    private var fullAccessGuide: some View {
        VStack(spacing: Space.xs) {
            Text("Turn on Full Access so Yank can show your clips:")
                .font(.yank(.caption))
                .foregroundStyle(Color.yankTextTertiary)
                .multilineTextAlignment(.center)
            Text(Self.fullAccessSteps.joined(separator: "  ›  "))
                .font(.yank(.caption2, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityHidden(true)
    }

    private var title: String {
        switch mode {
        case .needsFullAccess: return "Enable Full Access"
        case .empty:           return "No clips yet"
        case .storageError:    return "Storage unavailable"
        }
    }

    private var subtitle: String {
        switch mode {
        case .needsFullAccess: return "Turn on Full Access in Settings → Keyboards to see your clips."
        case .empty:           return "Copy something or open Yank, and it'll appear here."
        case .storageError:    return "Yank couldn't access its storage. Reinstall the app to restore access."
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .needsFullAccess:
            return "\(title). Turn on Full Access: \(Self.fullAccessSteps.joined(separator: ", then "))."
        default:
            return "\(title). \(subtitle)"
        }
    }
}
