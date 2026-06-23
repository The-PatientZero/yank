import SwiftUI

/// A content-aware list row for iOS — a kind icon (swatch / thumbnail / glyph), a
/// two-line excerpt, quiet metadata, tags, and the pin/bookmark marker. Kind
/// detection comes from the shared `ClipKind`, so it recognises clips exactly like
/// the Mac. Fonts use the Dynamic-Type ramp.
struct ClipRowView: View {
    let item: ClipboardItem
    let store: ClipStore
    var density: ClipDensity = .cozy
    var isHighlighted = false
    var isSelected = false
    var onTagTap: ((String) -> Void)? = nil

    /// A 1pt unit that tracks the user's preferred text size, so the density-driven
    /// `bodySize` below still grows with Dynamic Type. `@ScaledMetric` needs a literal
    /// anchor, so the per-density size is derived (unit × `readingSize`) rather than
    /// stored directly — Snug/Cozy/Airy change the base, Dynamic Type still scales it.
    @ScaledMetric(relativeTo: .body) private var scaleUnit: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: ClipKind { item.kind }
    private var stacksMetadata: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The iOS clip-reading size by density, anchored to `IOSType.readingBody` (19pt — a
    /// deliberate +2 over the 17pt system body) so even Snug stays at system body. Density
    /// modulates the reading size by ±2 rather than borrowing the compact macOS `bodyFont`
    /// (12–14pt), which would push the primary clip content *below* system body on iOS.
    private var readingSize: CGFloat {
        switch density {
        case .snug: return IOSType.readingBody - 2  // 17
        case .cozy: return IOSType.readingBody       // 19
        case .airy: return IOSType.readingBody + 2   // 21
        }
    }
    private var bodySize: CGFloat { scaleUnit * readingSize }
    private var excerptLineLimit: Int {
        stacksMetadata ? max(3, density.excerptLines + 1) : density.excerptLines
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            icon

            VStack(alignment: .leading, spacing: Space.xxs) {
                primaryText

                if let detail = secondaryDetail {
                    Text(detail)
                        .font(.yank(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(stacksMetadata ? 2 : 1)
                        .truncationMode(kind.isLink ? .middle : .tail)
                }

                if !item.tags.isEmpty {
                    HStack(spacing: Space.xs) {
                        TagChip(label: item.tags[0], onTap: onTagTap.map { tap in { tap(item.tags[0]) } })
                        if item.tags.count > 1 {
                            Text("+\(item.tags.count - 1)")
                                .font(.yank(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if stacksMetadata {
                    metadata
                        .padding(.top, Space.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !stacksMetadata {
                metadata
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, density.rowVerticalPadding)
        .background(rowBackground)
        .overlay(RoundedRectangle(cornerRadius: clipRowCornerRadius).strokeBorder(borderStyle, lineWidth: isSelected ? Stroke.focusRing : Hairline.width))
        .scaleEffect(isHighlighted && !reduceMotion ? 1.006 : 1)
        .contentShape(RoundedRectangle(cornerRadius: clipRowCornerRadius))
        .animation(IOSMotion.quick(reduceMotion), value: isHighlighted)
        .animation(IOSMotion.state(reduceMotion), value: isSelected)
    }

    /// Selection/highlight wash and border read from the environment `.tint` — the chosen
    /// theme accent the history root sets — so the row matches the pins and swipe actions
    /// instead of the system accent.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: clipRowCornerRadius)
            .fill(AnyShapeStyle(.tint).opacity(fillOpacity))
    }

    private var fillOpacity: Double {
        if isSelected { return 0.14 }
        return isHighlighted ? 0.10 : 0
    }

    private var borderStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint.opacity(0.55)) }
        if isHighlighted { return AnyShapeStyle(.tint.opacity(0.28)) }
        // A subtle resting hairline so list rows carry the same edge density as the grid
        // tiles (which always draw `Color.yankHairline`) instead of relying on the `List`
        // separators alone. `yankHairline` is a solid warm ink, so it stays semantic in
        // dark mode and honours Reduce Transparency (no alpha to flatten).
        return AnyShapeStyle(Color.yankHairline)
    }

    @ViewBuilder private var metadata: some View {
        if stacksMetadata {
            HStack(spacing: Space.xs) {
                RichContentBadge(state: item.richContentState, font: .yank(.caption))
                Text(item.relativeAge)
                    .font(.yank(.caption))
                    .foregroundStyle(Color.yankTextTertiary)
                ClipStatusBadge(item: item, font: .yank(.caption))
            }
        } else {
            VStack(alignment: .trailing, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    RichContentBadge(state: item.richContentState, font: .yank(.caption))
                    Text(item.relativeAge)
                        .font(.yank(.caption))
                        .foregroundStyle(Color.yankTextTertiary)
                }
                ClipStatusBadge(item: item, font: .yank(.caption))
            }
        }
    }

    @ViewBuilder private var icon: some View {  // swatch / thumbnail / glyph
        switch kind {
        case let .color(color, _):
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(color)
                .frame(width: IconSize.clipRow, height: IconSize.clipRow)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Color.yankSubtleBorder, lineWidth: Hairline.width))
        case .image:
            ClipThumbnailView(item: item, store: store)
                .frame(width: IconSize.clipRow, height: IconSize.clipRow)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        default:
            ClipKindIcon(glyph: kind.glyph)
        }
    }

    @ViewBuilder private var primaryText: some View {
        if case let .link(url) = kind {
            Text(url.host ?? url.absoluteString)
                .font(.system(size: bodySize, weight: .medium))
                .lineLimit(stacksMetadata ? 2 : 1)
                .truncationMode(.middle)
        } else {
            Text(item.excerpt)
                .font(.system(size: bodySize, design: kind.isCode ? .monospaced : .default))
                .lineLimit(excerptLineLimit)
        }
    }

    /// Secondary line — derivation shared with the macOS row via `ClipKind`.
    private var secondaryDetail: String? { kind.secondaryDetail(sourceApp: item.sourceApp) }
}
