import Foundation

/// A semantic feedback moment in Yank — *what happened*, not *how it feels*. Call sites speak in
/// cues (`capture`, `paste`, …); the app's feedback layer maps each to a concrete tactile/audible
/// channel. Kept in `YankCore` (no AppKit) so the cue→pattern decision is unit-tested in isolation.
public enum HapticCue: Sendable, CaseIterable {
    /// A clip was captured into history.
    case capture
    /// A clip was pasted into the frontmost app.
    case paste
    /// An item was pinned or unpinned.
    case pin
    /// An item was removed.
    case delete

    /// The tactile pattern this cue performs. Encodes a deliberate feel:
    /// discrete confirmations are `.generic`; "snap into place" actions are `.alignment`.
    public var pattern: HapticPattern {
        switch self {
        case .capture, .paste, .delete: .generic
        case .pin: .alignment
        }
    }
}

/// The tactile patterns a trackpad performer supports. Mirrors the AppKit patterns used by
/// clipboard cues but stays dependency-free so `YankCore` (and its tests) never import AppKit.
public enum HapticPattern: Sendable, Equatable {
    case generic
    case alignment
}
