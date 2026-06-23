import SwiftUI

/// The menu-bar command panel — a warm, designed replacement for the system
/// `NSMenu`, shown in an `NSPopover` on right-click. An `NSPopover`-hosted SwiftUI
/// view doesn't inherit `NSMenu`'s arrow-key navigation, so the rows opt into
/// `@FocusState` and drive ↑↓/Return themselves.
struct StatusMenuView: View {
    let shortcut: String
    let shortcutOpenTarget: ShortcutOpenTarget
    let isPaused: Bool
    let ignoreNextCopyArmed: Bool
    let hotkeyUnavailable: Bool
    let itemCount: Int
    let updateMenu: UpdateMenuPresentation
    let onOpenQuickPicker: () -> Void
    let onOpenHistory: () -> Void
    let onTogglePause: () -> Void
    let onIgnoreNextCopy: () -> Void
    let onFixShortcut: () -> Void
    let onSettings: () -> Void
    let onUpdateAction: (UpdateMenuActionID) -> Void
    let onClear: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void

    fileprivate enum Layout {
        static let panelWidth: CGFloat = 256
        static let iconColumn: CGFloat = 18
    }

    enum Row: Int, CaseIterable, Hashable {
        case openQuickPicker, openHistory, togglePause, ignoreNextCopy, fixShortcut, settings, update, restart, quit, clear
    }

    @FocusState private var focused: Row?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                YankWordmark(size: TypeScale.title)
                Spacer()
                Text(isPaused ? "paused" : "\(itemCount) clips")
                    .font(.system(size: TypeScale.caption))
                    .foregroundColor(.yankTextTertiary)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.md)

            hairline
            MenuRow(icon: "list.bullet.rectangle.portrait", title: "Quick picker",
                    trailing: shortcutOpenTarget == .quickPicker ? shortcut : "",
                    row: .openQuickPicker, focused: $focused, action: onOpenQuickPicker)
            MenuRow(icon: "tray.full", title: "Full history",
                    trailing: shortcutOpenTarget == .fullHistory ? shortcut : "",
                    row: .openHistory, focused: $focused, action: onOpenHistory)
            MenuRow(icon: isPaused ? "play.circle" : "pause.circle",
                    title: isPaused ? "Resume capture" : "Pause capture",
                    row: .togglePause, focused: $focused, action: onTogglePause)
            MenuRow(icon: ignoreNextCopyArmed ? "eye.slash.fill" : "eye.slash",
                    title: ignoreNextCopyArmed ? "Ignoring next copy" : "Ignore next copy",
                    trailing: ignoreNextCopyArmed ? "✓" : "", active: ignoreNextCopyArmed,
                    row: .ignoreNextCopy, focused: $focused, action: onIgnoreNextCopy)
            if hotkeyUnavailable {
                MenuRow(icon: "exclamationmark.triangle.fill",
                        title: "Keyboard shortcut unavailable — set a new one in Settings",
                        destructive: true,
                        row: .fixShortcut, focused: $focused, action: onFixShortcut)
            }
            hairline
            MenuRow(icon: "slider.horizontal.3", title: "Settings",
                    row: .settings, focused: $focused, action: onSettings)
            updateRow
            hairline
            MenuRow(icon: "arrow.clockwise", title: "Restart Yank",
                    row: .restart, focused: $focused, action: onRestart)
            MenuRow(icon: "power", title: "Quit Yank", trailing: "⌘Q",
                    row: .quit, focused: $focused, action: onQuit)
            hairline
            MenuRow(icon: "trash", title: "Permanently clear all history", destructive: true,
                    row: .clear, focused: $focused, action: onClear)
        }
        .padding(.bottom, Space.sm)
        .frame(width: Layout.panelWidth)
        .background(menuBackground)
        .tint(AppTheme.active.foreground)
        // Arrow keys step the focus ring; the popover is the key window, so a focused
        // row keeps the move commands routed through the responder chain.
        .onMoveCommand { direction in
            switch direction {
            case .up:   focused = step(from: focused, by: -1)
            case .down: focused = step(from: focused, by: +1)
            default:    break
            }
        }
        // Land focus on the first row so ↑↓/Return work the moment the menu opens.
        .onAppear { focused = orderedRows.first ?? .openHistory }
    }

    @ViewBuilder private var menuBackground: some View {
        if reduceTransparency {
            Color.yankSurface
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    /// Wrap-around step through the focus ring (nil starts at the first target).
    private func step(from current: Row?, by delta: Int) -> Row {
        let all = orderedRows
        guard !all.isEmpty else { return .openHistory }
        guard let current, let idx = all.firstIndex(of: current) else { return all[0] }
        let next = (idx + delta + all.count) % all.count
        return all[next]
    }

    /// Every focusable row in display order.
    private var orderedRows: [Row] {
        Self.orderedRows(hotkeyUnavailable: hotkeyUnavailable, updateAction: updateMenu.action)
    }

    static func orderedRows(hotkeyUnavailable: Bool, updateAction: UpdateMenuActionID?) -> [Row] {
        var rows: [Row] = [.openQuickPicker, .openHistory, .togglePause, .ignoreNextCopy]
        if hotkeyUnavailable { rows.append(.fixShortcut) }
        rows.append(.settings)
        if updateAction != nil { rows.append(.update) }
        rows.append(contentsOf: [.restart, .quit, .clear])
        return rows
    }

    private func performUpdateAction() {
        guard let action = updateMenu.action else { return }
        onUpdateAction(action)
    }

    private var updateRow: some View {
        MenuRow(icon: updateMenu.icon,
                title: updateMenu.title,
                trailing: updateMenu.trailing,
                detail: updateMenu.detail,
                disabled: updateMenu.action == nil,
                active: updateMenu.isActive,
                working: updateMenu.isWorking,
                accessibilityHint: updateMenu.accessibilityHint,
                row: .update,
                focused: $focused,
                action: performUpdateAction)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.yankHairline)
            .frame(height: 0.5)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.xs)
    }
}

private struct MenuRow: View {
    let icon: String
    let title: String
    var trailing: String = ""
    var detail: String = ""
    var destructive: Bool = false
    var disabled: Bool = false
    var active: Bool = false
    var working: Bool = false
    var accessibilityHint: String = ""
    let row: StatusMenuView.Row
    @FocusState.Binding var focused: StatusMenuView.Row?
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: detail.isEmpty ? .center : .top, spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: TypeScale.control))
                    .frame(width: StatusMenuView.Layout.iconColumn, alignment: .center)
                    .foregroundColor(iconColor)
                    .padding(.top, detail.isEmpty ? 0 : 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title)
                        .font(.system(size: TypeScale.body))
                        .foregroundColor(titleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: TypeScale.caption))
                            .foregroundColor(.yankTextTertiary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.md)
                if working {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.68)
                        .accessibilityHidden(true)
                }
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: TypeScale.caption, design: .monospaced))
                        .foregroundColor(active ? AppTheme.active.foreground : .yankTextTertiary)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
            .background(rowFill)
            .opacity(isPressed ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .focusable(!disabled)
        .focused($focused, equals: row)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(accessibilityHint)
        // A pressed state for pointer taps, since `.plain` gives no built-in press cue.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var iconColor: Color {
        if disabled { return .yankTextTertiary }
        if destructive { return .yankDanger }
        return active ? AppTheme.active.foreground : .secondary
    }

    private var titleColor: Color {
        if disabled { return .yankTextTertiary }
        return destructive ? .yankDanger : .primary
    }

    @ViewBuilder private var rowFill: some View {
        if disabled {
            Color.clear
        } else if focused == row {
            // Keyboard focus gets the fill plus a faint accent edge so it reads as
            // "selected" even without the pointer.
            AppTheme.active.selectionFill
                .overlay(Rectangle().strokeBorder(AppTheme.active.foreground.opacity(0.5),
                                                  lineWidth: Hairline.width))
        } else if isHovered {
            AppTheme.active.selectionFill
        } else {
            Color.clear
        }
    }
}
