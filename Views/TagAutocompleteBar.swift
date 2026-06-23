import SwiftUI

/// The horizontal strip of `#tag` suggestions shown under the search field while the
/// user types `#`. Selecting a chip applies it as the active tag filter.
struct TagAutocompleteBar: View {
    var suggestions: [String]
    /// The filter already applied, if any — its chip gets a quiet "active" ring so the
    /// user can see at a glance which tag is currently narrowing the stream.
    var activeTag: String? = nil
    var onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(suggestions, id: \.self) { tag in
                    TagChip(label: tag, displayPrefix: "#", onTap: { onSelect(tag) })
                        .overlay(activeRing(for: tag))
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.sm)
        }
        // Fade the row's edges so a clipped chip reads as "more, keep scrolling" rather
        // than a hard cut. The transparent stops sit inside the row's own padding.
        .mask(edgeFade)
        .background(Color.yankRaised.opacity(0.78))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.yankHairline), alignment: .bottom)
    }

    /// A faint accent ring on the chip that matches the currently-applied filter.
    @ViewBuilder
    private func activeRing(for tag: String) -> some View {
        if tag == activeTag {
            Capsule()
                .strokeBorder(AppTheme.active.foreground.opacity(0.7), lineWidth: Stroke.focusRing)
        }
    }

    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.96),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
