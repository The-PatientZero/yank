import SwiftUI

/// What a clip *is*, inferred from its content. Drives the glyph, the type label,
/// and the accentable preview in every view mode — so you recognise a clip at a
/// glance instead of reading it. The content-sniffing itself lives in the pure
/// `ContentClassifier` (YankCore); this enum just maps the result onto its cases.
enum ClipKind: Equatable {
    case color(Color, raw: String)
    case link(URL)
    case image
    case code
    case email(String)
    case phone(String)
    case note

    /// SF Symbol shown when there is no richer preview (i.e. not a swatch/thumbnail).
    var glyph: String {
        switch self {
        case .color:  return "paintpalette"
        case .link:   return "link"
        case .image:  return "photo"
        case .code:   return "curlybraces"
        case .email:  return "envelope"
        case .phone:  return "phone"
        case .note:   return "text.alignleft"
        }
    }

    /// Short, lowercase type label ("link", "swatch", "code"…).
    var label: String {
        switch self {
        case .color:  return "swatch"
        case .link:   return "link"
        case .image:  return "image"
        case .code:   return "code"
        case .email:  return "email"
        case .phone:  return "phone"
        case .note:   return "note"
        }
    }

    /// Whether this clip is source code — drives monospaced rendering.
    var isCode: Bool {
        if case .code = self { return true }
        return false
    }

    /// Whether this clip is a single link — drives URL middle-truncation.
    var isLink: Bool {
        if case .link = self { return true }
        return false
    }

    /// The secondary line shown under a list row: the kind's own salient string (the full
    /// URL, the email address, the phone number) when it has one, otherwise the source app.
    /// Pure derivation shared by the macOS `ClipboardItemRow` and the iOS `ClipRowView` so the
    /// rule can't drift between platforms; the icon/thumbnail rendering stays local to each row.
    func secondaryDetail(sourceApp: String?) -> String? {
        switch self {
        case let .link(url):  return url.absoluteString
        case let .email(e):   return e
        case let .phone(p):   return p
        default:              return sourceApp
        }
    }
}

extension ClipboardItem {
    /// The inferred kind of this clip — memoised in `ClipPresentationCache`, since it's
    /// read several times per row on every render. `computeKind()` does the real work.
    var kind: ClipKind { ClipPresentationCache.presentation(for: self).kind }

    /// A single-line excerpt for the list and tile views — memoised alongside `kind`.
    var excerpt: String { ClipPresentationCache.presentation(for: self).excerpt }

    /// Max characters shown in a collapsed list/tile excerpt before eliding.
    private static let excerptLimit = 160

    /// The content-sniffing behind `kind` (color / link / email / phone / code / note),
    /// delegated to the pure `ContentClassifier`. Run once per clip id via the cache.
    func computeKind() -> ClipKind {
        if type == .image { return .image }
        let raw = (textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .note }

        if let (rgba, original) = ContentClassifier.cssColor(raw) {
            return .color(Color(red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.opacity),
                          raw: original)
        }
        if let url = ContentClassifier.linkURL(raw) { return .link(url) }
        if let email = ContentClassifier.email(raw) { return .email(email) }
        if let phone = ContentClassifier.phone(raw) { return .phone(phone) }
        if ContentClassifier.looksLikeCode(raw) { return .code }
        return .note
    }

    /// The whitespace-collapsed, elided excerpt behind `excerpt`. Splitting on
    /// whitespace runs (and rejoining) collapses + trims without compiling a regex.
    func computeExcerpt() -> String {
        let text = textContent ?? previewText
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > Self.excerptLimit
            ? String(collapsed.prefix(Self.excerptLimit)) + "…"
            : collapsed
    }
}
