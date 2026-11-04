import SwiftUI

/// Calm, informational line shown while history elements this version cannot read are being kept
/// on disk. Deliberately neutral: nothing is wrong, nothing is lost.
struct HeldClipsNotice: View {
    let count: Int

    /// Hand-written singular and plural; the app has no string catalogs.
    static func message(count: Int) -> String {
        count == 1
            ? "1 clip is kept but can't be shown by this version of Yank."
            : "\(count) clips are kept but can't be shown by this version of Yank."
    }

    /// Extra sentence for the Clear History confirmations, or `nil` when nothing is kept.
    static func clearWarning(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "This also removes 1 clip this version can't show."
            : "This also removes \(count) clips this version can't show."
    }

    private var labelFont: Font {
        #if os(iOS)
        .yank(.footnote)
        #else
        .system(size: TypeScale.caption)
        #endif
    }

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "archivebox")
                .font(labelFont)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(Self.message(count: count))
                .font(labelFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.message(count: count))
    }
}
