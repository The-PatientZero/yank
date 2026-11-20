import Foundation

/// A platform-neutral colour result (0...1 channels), so the CSS-colour parsing can live
/// in the pure core and the UI layer wraps it into a `SwiftUI.Color`.
struct RGBA: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double
}

/// The pure content-sniffing behind `ClipKind` — link / email / phone / code / CSS-colour
/// detection. No SwiftUI, no I/O, so the branchy heuristics (the kind of logic that rots
/// silently) are unit-tested headlessly; `ClipKind` just maps the result onto its cases.
enum ContentClassifier {

    /// A single http(s) URL with a host and no embedded whitespace.
    static func linkURL(_ raw: String) -> URL? {
        guard !raw.contains(where: \.isWhitespace),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// A single email address (one token, exactly one `@`, a dotted domain).
    static func email(_ raw: String) -> String? {
        guard !raw.contains(where: \.isWhitespace) else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              parts[1].contains("."), parts[1].last != "." else { return nil }
        return raw
    }

    /// A phone-like token: optional `+`, then digits and separators, ≥7 digits, no letters.
    static func phone(_ raw: String) -> String? {
        guard raw.count <= 24 else { return nil }
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let digits = raw.filter(\.isNumber)
        return digits.count >= 7 ? raw : nil
    }

    /// Heuristic: does this read like source code?
    static func looksLikeCode(_ raw: String) -> Bool {
        if raw.contains("{") && raw.contains("}") { return true }
        if raw.contains("```") { return true }
        let signals = ["func ", "function ", "const ", "let ", "var ", "def ", "class ",
                       "import ", "#include", "=>", "</", "println", "console.", "public ",
                       "private ", "return ", "$ ", "sudo ", "npm ", "git "]
        if signals.contains(where: raw.contains) { return true }
        // Several indented lines also suggests code.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        return lines.count >= 3 && indented.count >= 2
    }

    // MARK: CSS colour parsing (#RGB/#RRGGBB/#RRGGBBAA, rgb[a](), hsl[a]())

    /// Returns the parsed colour and the original (trimmed) string for display.
    static func cssColor(_ string: String) -> (rgba: RGBA, raw: String)? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty else { return nil }

        if lower.hasPrefix("#"), let rgba = parseHex(String(lower.dropFirst())) {
            return (rgba, trimmed)
        }
        if lower.hasPrefix("rgb"), let rgba = parseRGB(lower) { return (rgba, trimmed) }
        if lower.hasPrefix("hsl"), let rgba = parseHSL(lower) { return (rgba, trimmed) }
        return nil
    }

    private static func parseHex(_ hexStr: String) -> RGBA? {
        let hex = hexStr.filter(\.isHexDigit)
        switch hex.count {
        case 3:  return parseHex6(hex.map { "\($0)\($0)" }.joined())
        case 6:  return parseHex6(hex)
        case 8:  return parseHex8(hex)
        default: return nil
        }
    }

    private static func parseHex6(_ hex: String) -> RGBA? {
        guard let value = UInt64(hex, radix: 16) else { return nil }
        return RGBA(red: Double((value >> 16) & 0xFF) / 255,
                    green: Double((value >> 8) & 0xFF) / 255,
                    blue: Double(value & 0xFF) / 255,
                    opacity: 1)
    }

    private static func parseHex8(_ hex: String) -> RGBA? {
        guard let value = UInt64(hex, radix: 16) else { return nil }
        return RGBA(red: Double((value >> 24) & 0xFF) / 255,
                    green: Double((value >> 16) & 0xFF) / 255,
                    blue: Double((value >> 8) & 0xFF) / 255,
                    opacity: Double(value & 0xFF) / 255)
    }

    private static func parseRGB(_ string: String) -> RGBA? {
        let isRGBA = string.hasPrefix("rgba")
        guard let comps = numericComponents(string, prefix: isRGBA ? "rgba" : "rgb"),
              comps.count >= 3 else { return nil }
        let a = isRGBA && comps.count >= 4 ? comps[3] : 1.0
        return RGBA(red: comps[0] / 255, green: comps[1] / 255, blue: comps[2] / 255, opacity: a)
    }

    private static func parseHSL(_ string: String) -> RGBA? {
        let isHSLA = string.hasPrefix("hsla")
        guard let comps = numericComponents(string, prefix: isHSLA ? "hsla" : "hsl"),
              comps.count >= 3 else { return nil }
        let a = isHSLA && comps.count >= 4 ? comps[3] : 1.0
        let (r, g, b) = hslToRGB(h: comps[0], s: comps[1] / 100, l: comps[2] / 100)
        return RGBA(red: r, green: g, blue: b, opacity: a)
    }

    /// Pulls the comma-separated numbers out of `prefix(...)`.
    private static func numericComponents(_ string: String, prefix: String) -> [Double]? {
        guard string.hasPrefix(prefix), string.hasSuffix(")"),
              let open = string.firstIndex(of: "(") else { return nil }
        let inner = string[string.index(after: open)..<string.index(before: string.endIndex)]
        return inner.split(separator: ",").compactMap {
            Double($0.filter { $0.isNumber || $0 == "." || $0 == "-" })
        }
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let h = h.truncatingRemainder(dividingBy: 360)
        let s = max(0, min(1, s)), l = max(0, min(1, l))
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        let hn = h / 360
        return (hue(hn + 1/3), hue(hn), hue(hn - 1/3))
    }
}
