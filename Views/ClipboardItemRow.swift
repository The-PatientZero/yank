import SwiftUI

/// Single row for the List / Split modes — a content-aware icon, a two-line excerpt,
/// and quiet metadata. Type detection + colour parsing live in `ClipKind`.
struct ClipboardItemRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let isPrimarySelection: Bool
    let isMultiSelected: Bool
    var density: ClipDensity = .cozy
    var quickIndex: Int? = nil
    var pastesOnClick = true
    var onTagTap: ((String) -> Void)? = nil

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: ClipKind { item.kind }

    private var backgroundColor: Color {
        if isMultiSelected && !isPrimarySelection {
            return Color.yankMultiSelect
        } else if isPrimarySelection {
            // Same accent source the tile uses for its focused fill (the AA-safe
            // `foreground`), so the selection hue stays identical across List ↔ Grid.
            // A touch denser than the tile's, since the row fills over the window
            // surface rather than a raised card.
            return AppTheme.active.foreground.opacity(0.16)
        } else if isHovered {
            return Color.yankHover
        }
        return Color.clear
    }

    /// Secondary line: the full URL for links, the address/number for email/phone,
    /// otherwise the source app. Derivation is shared with the iOS row via `ClipKind`.
    private var secondaryDetail: String? { kind.secondaryDetail(sourceApp: item.sourceApp) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            icon

            VStack(alignment: .leading, spacing: Space.xxs) {
                primaryText

                if let detail = secondaryDetail {
                    Text(detail)
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                        .lineLimit(1)
                        .truncationMode(kind.isLink ? .middle : .tail)
                }

                if !item.tags.isEmpty {
                    HStack(spacing: Space.xs) {
                        TagChip(label: item.tags[0], onTap: { onTagTap?(item.tags[0]) })
                        if item.tags.count > 1 {
                            Text("+\(item.tags.count - 1)")
                                .font(.system(size: TypeScale.micro))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, Space.xxs)
                }
            }

            Spacer(minLength: Space.sm)

            VStack(alignment: .trailing, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    RichContentBadge(state: item.richContentState)
                    Text(item.relativeAge)
                        .font(.system(size: TypeScale.micro))
                        .foregroundColor(.yankTextTertiary)
                        .help(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                }

                ClipStatusBadge(item: item)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, density.rowVerticalPadding)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: clipRowCornerRadius))
        .overlay(alignment: .topTrailing) {
            if let key = quickIndex {
                QuickKeyBadge(key: key)
                    .padding(.top, Space.xs)
                    .padding(.trailing, Space.xs)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: clipRowCornerRadius)
                .strokeBorder(borderColor, lineWidth: isPrimarySelection ? Stroke.focusRing : Hairline.width)
        )
        .shadow(color: .black.opacity(rowShadowOpacity), radius: isPrimarySelection ? 7 : 4, y: 1)
        .scaleEffect(isHovered && !isPrimarySelection && !reduceMotion ? 1.004 : 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(pastesOnClick ? "Click to paste" : "Double-click to paste")
        .animation(YankMotion.quick(reduceMotion), value: isHovered)
        .animation(YankMotion.state(reduceMotion), value: isPrimarySelection)
        .animation(YankMotion.state(reduceMotion), value: isMultiSelected)
    }

    private var borderColor: Color {
        if isPrimarySelection {
            return AppTheme.active.foreground.opacity(0.42)
        }
        if isMultiSelected {
            return Color.yankMultiSelectSoftBorder
        }
        return isHovered ? Color.yankHairline : Color.clear
    }

    private var rowShadowOpacity: Double {
        if isPrimarySelection {
            return 0.055
        }
        return isHovered ? 0.035 : 0
    }

    @ViewBuilder
    private var primaryText: some View {
        if case let .link(url) = kind {
            Text(url.host ?? url.absoluteString)
                .font(.system(size: density.bodyFont, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        } else {
            Text(item.excerpt)
                .font(.system(size: density.bodyFont, design: codeDesign))
                .foregroundColor(.primary)
                .lineLimit(density.excerptLines)
        }
    }

    private var codeDesign: Font.Design {
        if case .code = kind { return .monospaced }
        return .default
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case let .color(color, _):
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(color)
                .frame(width: IconSize.clipRow, height: IconSize.clipRow)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .stroke(Color.yankSubtleBorder, lineWidth: Hairline.width)
                )
        case .image:
            ClipThumbnail(item: item, store: store, contentMode: .fill)
                .frame(width: IconSize.clipRow, height: IconSize.clipRow)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        default:
            ClipKindIcon(glyph: kind.glyph)
        }
    }
}
