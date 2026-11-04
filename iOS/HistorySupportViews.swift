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

/// The visible Copy button on a row or tile. It is a sibling of the row's open button, never part
/// of its label, so a tap on it copies without opening details and VoiceOver reads it as its own
/// element. The same copy path as the swipe and menu Copy runs behind `action`.
struct ClipCopyButton: View {
    let excerpt: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.yank(.subheadline))
                .foregroundStyle(.secondary)
                .frame(width: ControlTarget.touch, height: ControlTarget.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy \(excerpt)")
    }
}

/// A button shown next to a capture method, for the methods iOS lets Yank link to.
struct CaptureSetupAction {
    let title: String
    let perform: () -> Void
}

/// Opens Yank's own page in the iOS Settings app, the only deep link iOS supports.
@MainActor
enum AppSettingsLink {
    static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

struct CaptureSetupRow: View {
    let systemImage: String
    let title: String
    let description: String
    let isConfirmed: Bool
    var action: CaptureSetupAction?
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
                if let action {
                    Button(action.title, action: action.perform)
                        .buttonStyle(.bordered)
                        .frame(minHeight: ControlTarget.touch)
                        .padding(.top, Space.xxs)
                }
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

/// Shown above an empty history while sync is on but the iCloud account cannot sync. It says
/// Yank works without iCloud; both actions end the situation, so it needs no dismiss button.
struct ICloudSignedOutBanner: View {
    let isRestricted: Bool
    let onUseWithoutICloud: () -> Void

    private static let signedOutMessage = "Yank works without iCloud. To sync, sign in to iCloud in Settings."

    private var message: String {
        isRestricted ? SyncFailure(kind: .accountRestricted).message : Self.signedOutMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "icloud.slash")
                    .font(.yank(.footnote, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.yank(.footnote))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.md) {
                if !isRestricted {
                    Button(SyncCopy.openSettingsTitle, action: AppSettingsLink.open)
                }
                Button("Use Without iCloud", action: onUseWithoutICloud)
            }
            .buttonStyle(.bordered)
            .font(.yank(.footnote, weight: .semibold))
            .frame(minHeight: ControlTarget.touch)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yankRaised)
        .overlay(
            Rectangle().frame(height: Hairline.width).foregroundColor(Color.yankHairline),
            alignment: .bottom
        )
        .accessibilityElement(children: .contain)
    }
}

/// Shown when automatic capture keeps coming back empty although the clipboard holds text,
/// which is what a denied "Paste from Other Apps" setting looks like.
struct PasteDeniedBanner: View {
    private static let message = "Yank can't read the clipboard. Allow Paste in Settings"
    private static let fix = "Set Paste from Other Apps to Allow."

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "doc.on.clipboard")
                    .font(.yank(.footnote, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(Self.message)
                        .font(.yank(.footnote, weight: .semibold))
                    Text(Self.fix)
                        .font(.yank(.footnote))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button(SyncCopy.openSettingsTitle, action: AppSettingsLink.open)
                .buttonStyle(.bordered)
                .font(.yank(.footnote, weight: .semibold))
                .frame(minHeight: ControlTarget.touch)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yankRaised)
        .overlay(
            Rectangle().frame(height: Hairline.width).foregroundColor(Color.yankHairline),
            alignment: .bottom
        )
        .accessibilityElement(children: .contain)
    }
}
