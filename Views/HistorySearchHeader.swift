import SwiftUI

/// The history window header: wordmark, view-mode picker, result count, Settings button, and search field.
struct HistorySearchHeader: View {
    @Binding var searchText: String
    @Binding var activeTagFilter: String?
    @Binding var viewMode: ClipViewMode
    @FocusState.Binding var isSearchFocused: Bool
    var hasTags: Bool
    var count: Int
    var keepWindowOpen: Bool
    var reduceMotion: Bool
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center, spacing: Space.md) {
                YankWordmark()
                Spacer()
                ViewModePicker(selection: $viewMode, reduceMotion: reduceMotion)
                Text(count == 0 ? "" : "\(count)")
                    .font(.system(size: TypeScale.input, weight: .regular, design: .serif))
                    .foregroundColor(.yankTextTertiary)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityLabel(count == 0 ? "No clips" : "\(count) clips")
                if keepWindowOpen {
                    Image(systemName: "pin.fill")
                        .font(.system(size: TypeScale.caption, weight: .medium))
                        .foregroundColor(.yankTextTertiary)
                        .rotationEffect(.degrees(45))
                        .accessibilityLabel("Window stays open")
                        .help("Window stays open — outside clicks won't close it. Change in Settings.")
                }
                IconButton(systemName: "gearshape", label: "Settings",
                           size: TypeScale.input, weight: .medium, action: onSettings)
            }

            HStack(spacing: Space.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(isSearchFocused ? AppTheme.active.foreground.opacity(0.85) : .yankTextTertiary)
                    .font(.system(size: TypeScale.input, weight: .medium))
                    .accessibilityHidden(true)

                if let tag = activeTagFilter {
                    TagChip(label: tag, displayPrefix: "#", onRemove: { activeTagFilter = nil })
                        .transition(filterTransition)
                }

                TextField(hasTags ? "Search · #tag · @app" : "Search your clips · @app", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: TypeScale.title, weight: .regular))
                    .focused($isSearchFocused)

                if !searchText.isEmpty {
                    IconButton(systemName: "xmark.circle.fill", label: "Clear search",
                               size: TypeScale.input) { searchText = "" }
                        .transition(filterTransition)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .glassControl(interactive: false)
            .overlay(
                Capsule()
                    .strokeBorder(isSearchFocused ? AppTheme.active.foreground.opacity(0.38) : Color.clear,
                                  lineWidth: Stroke.focusRing)
            )
            .animation(YankMotion.quick(reduceMotion), value: isSearchFocused)
            .animation(YankMotion.quick(reduceMotion), value: searchText.isEmpty)
            .animation(YankMotion.quick(reduceMotion), value: activeTagFilter)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.lg)
    }

    private var filterTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity)
    }
}
