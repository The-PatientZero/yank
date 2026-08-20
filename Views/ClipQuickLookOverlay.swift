import SwiftUI

/// Focused-clip Quick Look overlay. Caller gates presentation on `showQuickLook &&
/// selectedItem != nil`; this view owns sizing and the scrim's tap-to-dismiss.
struct ClipQuickLookOverlay: View {
    var store: ClipboardStore
    var selectedItems: [ClipboardItem]
    var model: ClipDetailModel
    var onCopy: (ClipboardItem) -> Void
    var onDownloadImages: () -> Void
    var onDelete: (ClipboardItem) -> Void
    var onDismiss: () -> Void

    @AccessibilityFocusState private var closeButtonFocused: Bool

    private enum Size {
        static let minWidth: CGFloat = 300
        static let maxWidth: CGFloat = 420
        static let minHeight: CGFloat = 340
        static let maxHeight: CGFloat = 500
    }

    var body: some View {
        GeometryReader { geo in
            let width = min(Size.maxWidth, max(Size.minWidth, geo.size.width - 2 * Space.xxl))
            let height = min(Size.maxHeight, max(Size.minHeight, geo.size.height - 2 * Space.xxl))

            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                quickLookCard(width: width, height: height)
                    .padding(Space.xxl)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("Quick Look preview")
            .accessibilityHint("Close returns to the clipboard history.")
            .onAppear { closeButtonFocused = true }
            .onExitCommand(perform: onDismiss)
        }
    }

    private func quickLookCard(width: CGFloat, height: CGFloat) -> some View {
        ClipDetailView(store: store, selectedItems: selectedItems, model: model,
                       onCopy: onCopy, onDownloadImages: onDownloadImages, onDelete: onDelete)
            .frame(width: width, height: height)
            .glassSurface(cornerRadius: Radius.window)
            .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
            .overlay(alignment: .topLeading) {
                closeButton
                    .padding(Space.sm)
            }
    }

    private var closeButton: some View {
        IconButton(systemName: "xmark.circle.fill",
                   label: "Close Quick Look",
                   help: "Close Quick Look (Esc)",
                   tint: .secondary,
                   size: TypeScale.body,
                   weight: .semibold,
                   hitTarget: 28,
                   action: onDismiss)
            .accessibilityFocused($closeButtonFocused)
            .accessibilitySortPriority(1)
    }
}
