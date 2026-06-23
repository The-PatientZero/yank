import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSWindowController {
    private let axPermission: AccessibilityPermission

    init(axPermission: AccessibilityPermission, syncAvailable: Bool) {
        self.axPermission = axPermission
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Yank"
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: WelcomeView(
                axPermission: axPermission,
                syncAvailable: syncAvailable,
                onDismiss: { [weak self] in self?.close() }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let fadeInDuration: TimeInterval = 0.24

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let window else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeInDuration
            window.animator().alphaValue = 1
        }
    }

    override func close() {
        UserDefaults.standard.set(true, forKey: "yankWelcomeSeen")
        super.close()
    }
}

private struct WelcomeView: View {
    let axPermission: AccessibilityPermission
    let syncAvailable: Bool
    let onDismiss: () -> Void

    private let manager = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            HStack(spacing: Space.lg) {
                YankBrandMark(size: 64)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Welcome to Yank")
                        .font(.system(size: TypeScale.display, weight: .semibold, design: .serif))
                    Text("Designed to disappear. Built to remember.")
                        .font(.system(size: TypeScale.body))
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            VStack(alignment: .leading, spacing: Space.md) {
                welcomeRow(
                    icon: "keyboard",
                    title: "Your global shortcut",
                    body: "Press \(shortcutDisplay) from any app to open your history."
                )

                Divider().overlay(Color.yankHairline)

                welcomeRow(
                    icon: "icloud",
                    title: syncAvailable ? "Synced and on hand" : "Local and on hand",
                    body: syncAvailable
                        ? "Clips sync across your devices over iCloud, and Yank lives in the menu bar — its mark sits up top, near the clock."
                        : "This build keeps clips on this Mac. Yank lives in the menu bar — its mark sits up top, near the clock."
                )

                Divider().overlay(Color.yankHairline)

                axRow

                Divider().overlay(Color.yankHairline)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(size: TypeScale.body, weight: .medium))
                        Text("Yank starts quietly in the background when you log in.")
                            .font(.system(size: TypeScale.caption))
                            .foregroundColor(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Toggle("Launch at login", isOn: Binding(
                        get: { manager.launchAtLogin },
                        set: { _ = manager.toggleLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            .padding(Space.lg)
            .background(Color.yankRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))

            HStack {
                Spacer()
                Button("Get started") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                    .accessibilityHint("Closes this window and starts using Yank.")
            }
        }
        .padding(Space.xxl)
        .frame(width: 460)
        .background(YankWindowBackground())
    }

    @ViewBuilder
    private var axRow: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: axPermission.isTrusted ? "checkmark.circle.fill" : "lock.circle")
                .foregroundColor(axPermission.isTrusted ? .yankSuccess : .secondary)
                .font(.system(size: TypeScale.title))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Accessibility access")
                    .font(.system(size: TypeScale.body, weight: .medium))
                if axPermission.isTrusted {
                    Text("Granted — Yank can auto-paste when you pick a clip.")
                        .font(.system(size: TypeScale.caption))
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Needed for auto-paste. Your clip always lands on the clipboard even without it.")
                        .font(.system(size: TypeScale.caption))
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Grant in System Settings →") {
                        AccessibilityPermission.requestPrompt()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .foregroundColor(AppTheme.active.foreground)
                }
            }
        }
    }

    private func welcomeRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon)
                .foregroundColor(AppTheme.active.foreground)
                .font(.system(size: TypeScale.title))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.system(size: TypeScale.body, weight: .medium))
                Text(body)
                    .font(.system(size: TypeScale.caption))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shortcutDisplay: String {
        "\(manager.hotkeyModifiers.displayString)\(keyCodeNames[manager.hotkeyKeyCode] ?? "?")"
    }
}
