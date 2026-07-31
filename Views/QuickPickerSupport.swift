import SwiftUI
import Cocoa
import Observation

@MainActor
@Observable
final class QuickPickerSmartSearchState {
    typealias Search = @MainActor @Sendable (String) async -> [ClipboardItem]

    private(set) var results: [ClipboardItem]?
    private(set) var isInterpreting = false
    private(set) var resultRevision = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    var hasOwnedTask: Bool { task != nil }

    func interpret(_ phrase: String, using search: @escaping Search) {
        guard !phrase.isEmpty else {
            queryDidChange()
            return
        }

        invalidateOwnedRequest()
        let requestID = UUID()
        self.requestID = requestID
        isInterpreting = true

        let task = Task { @MainActor [weak self, search] in
            let results = await search(phrase)
            guard let self,
                  !Task.isCancelled,
                  self.requestID == requestID else {
                return
            }
            self.task = nil
            self.requestID = nil
            self.results = results
            self.isInterpreting = false
            self.resultRevision &+= 1
        }
        self.task = task
    }

    func queryDidChange() {
        invalidateOwnedRequest()
        results = nil
    }

    func disappear() {
        invalidateOwnedRequest()
    }

    private func invalidateOwnedRequest() {
        task?.cancel()
        task = nil
        requestID = nil
        isInterpreting = false
    }
}

struct QuickPickerThumbnailFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: IconSize.clipRow, height: IconSize.clipRow)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

struct PickerIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: TypeScale.control, weight: .medium))
                .frame(width: ControlTarget.compact, height: ControlTarget.compact)
                .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .foregroundColor(isHovered ? AppTheme.active.foreground : .yankTextTertiary)
        .background(
            isHovered ? Color.yankHover : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.sm)
        )
        .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
        .onHover { isHovered = $0 }
        .animation(YankMotion.quick(reduceMotion), value: isHovered)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct QuickPickerKeyMonitor: NSViewRepresentable {
    struct Handlers {
        let onUp: () -> Void
        let onDown: () -> Void
        let onEnter: () -> Void
        let onCopy: () -> Void
        let onPasteAsText: () -> Void
        let onEscape: () -> Void
        let onOpenFullHistory: () -> Void
        let onFocusSearch: () -> Void
        let onPasteIndex: (Int) -> Void
    }

    let handlers: Handlers

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak view] event in
            guard WindowKeyEventScope.shouldHandle(
                monitoredWindow: view?.window,
                keyWindow: NSApp.keyWindow
            ) else { return event }
            return handle(event)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let directActions: [UInt16: () -> Void] = [
            126: handlers.onUp,
            125: handlers.onDown,
            53: handlers.onEscape
        ]
        if let action = directActions[event.keyCode] {
            action()
            return nil
        }
        if event.keyCode == 36 {
            handleReturn(modifiers: event.modifierFlags)
            return nil
        }
        return handleCommandShortcut(event)
    }

    private func handleReturn(modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.option) {
            handlers.onPasteAsText()
        } else if modifiers.contains(.command) {
            handlers.onCopy()
        } else {
            handlers.onEnter()
        }
    }

    private func handleCommandShortcut(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command) else { return event }
        switch event.keyCode {
        case 3:
            handlers.onFocusSearch()
        case 31:
            handlers.onOpenFullHistory()
        default:
            guard let index = Self.quickIndex(for: event.keyCode) else { return event }
            handlers.onPasteIndex(index)
        }
        return nil
    }

    private static func quickIndex(for keyCode: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][keyCode]
    }

    final class Coordinator {
        var monitor: Any?

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}
