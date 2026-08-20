import AppKit

/// Maps a semantic `HapticCue` to `NSHapticFeedbackManager`, gated by `isEnabled`. A no-op on
/// Macs without a Force Touch trackpad, so call sites never need to branch on hardware. Driven
/// through `Feedback`, not called directly.
@MainActor
enum Haptics {
    static func fire(_ cue: HapticCue, isEnabled: Bool) {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(cue.pattern.appKitPattern, performanceTime: .now)
    }
}

private extension HapticPattern {
    /// 1:1 bridge to AppKit at the edge — `HapticPattern` stays AppKit-free so `YankCore` can own it.
    var appKitPattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .generic: .generic
        case .alignment: .alignment
        }
    }
}
