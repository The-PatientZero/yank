import SwiftUI

/// The colour Yank wears. Stored by `id` in settings; applied as `.tint(_:)` at the
/// window roots, to the "Yank." dot, and to every selection / focus / active state.
enum AppTheme: String, CaseIterable, Identifiable {
    case amber, terracotta, rose, plum, indigo, teal, forest, graphite

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Saturated accent (the fill / swatch). Amber matches the app icon.
    var color: Color {
        switch self {
        case .amber:      return Color(red: 0.984, green: 0.749, blue: 0.141) // #FBBF24
        case .terracotta: return Color(red: 0.886, green: 0.408, blue: 0.235) // #E2683C
        case .rose:       return Color(red: 0.957, green: 0.247, blue: 0.369) // #F43F5E
        case .plum:       return Color(red: 0.659, green: 0.333, blue: 0.969) // #A855F7
        case .indigo:     return Color(red: 0.388, green: 0.400, blue: 0.945) // #6366F1
        case .teal:       return Color(red: 0.078, green: 0.722, blue: 0.651) // #14B8A6
        case .forest:     return Color(red: 0.133, green: 0.627, blue: 0.420) // #22A06B
        case .graphite:   return Color(red: 0.392, green: 0.455, blue: 0.545) // #64748B
        }
    }

    static func from(id: String?) -> AppTheme {
        AppTheme(rawValue: id ?? "") ?? .amber
    }

    /// A glyph/label colour with enough contrast to sit *directly on the saturated `color`
    /// swatch* — e.g. the selected-accent checkmark. White only clears AA on the two darkest
    /// accents (indigo/graphite); every other swatch is light enough that white falls below
    /// AA (amber is 1.67:1), so they take a warm near-black instead. Verified ≥4.4:1 on every
    /// swatch — the swatch fill is the same in both appearances, so this needn't adapt.
    var onAccent: Color {
        switch self {
        case .indigo, .graphite: return .white
        default: return Color(red: 0.102, green: 0.098, blue: 0.086) // warm near-black (#1A1916)
        }
    }
}

extension AppTheme {
    /// Accent safe to use as a foreground, glyph, or `.tint` — WCAG-AA verified
    /// against both light and dark surfaces. The raw `color` is a fill behind primary
    /// text only; never a foreground (e.g. amber is 1.67:1 on white). Resolves via the
    /// platform `yankDynamic`, so it works on macOS and iOS.
    var foreground: Color {
        switch self {
        case .amber:      return .yankDynamic(light: 0x826312, dark: 0xFBBF24)
        case .terracotta: return .yankDynamic(light: 0xB24A22, dark: 0xF08A5D)
        case .rose:       return .yankDynamic(light: 0xC02B47, dark: 0xFB7185)
        case .plum:       return .yankDynamic(light: 0x8B3FD6, dark: 0xC084FC)
        case .indigo:     return .yankDynamic(light: 0x4F46E5, dark: 0x818CF8)
        case .teal:       return .yankDynamic(light: 0x0A7066, dark: 0x2DD4BF)
        case .forest:     return .yankDynamic(light: 0x0A7853, dark: 0x34D399)
        case .graphite:   return .yankDynamic(light: 0x5C6A7F, dark: 0x94A3B8)
        }
    }
}
