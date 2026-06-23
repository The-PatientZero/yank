import AppKit

/// The tactile feedback channel: maps a semantic `HapticCue` to the trackpad's
/// `NSHapticFeedbackManager` and performs it — but only when the user has haptics enabled. A no-op
/// on Macs without a Force Touch trackpad (the system performer simply does nothing there), so call
/// sites never branch on hardware. Driven through `Feedback`, not called directly.
@MainActor
enum Haptics {
    static func fire(_ cue: HapticCue) {
        guard SettingsManager.shared.hapticFeedbackEnabled else { return }
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
