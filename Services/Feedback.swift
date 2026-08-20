import Foundation

enum CaptureFeedbackPolicy {
    /// A capture sound is useful only while it still feels causally connected to the copy.
    /// Normal polling can already add up to 0.5 seconds before this timestamp is recorded.
    static let maximumAudibleLatency: TimeInterval = 0.75

    static func allowsSound(observedAt: Date?, now: Date = Date()) -> Bool {
        guard let observedAt else { return true }
        return max(0, now.timeIntervalSince(observedAt)) <= maximumAudibleLatency
    }
}

/// Fire-and-forget: a call site emits a semantic cue (`capture`, `paste`, `pin`, …), fanned out
/// to every channel, each self-gating on its own setting so emitting is always safe. Animation
/// stays at the view layer, not here; `Sounds`/`Haptics` stay pure functions of their arguments.
@MainActor
enum Feedback {
    static func emit(
        _ cue: HapticCue,
        allowsSound: Bool = true,
        settings: FeedbackSettings = SettingsManager.shared.feedbackSettings
    ) {
        Haptics.fire(cue, isEnabled: settings.hapticFeedbackEnabled)
        if allowsSound {
            Sounds.play(
                cue,
                isEnabled: settings.soundEffectsEnabled,
                choice: settings.soundEffectChoice
            )
        }
    }
}

/// The non-visual feedback preferences a cue needs, as a value snapshot — the same shape
/// `CaptureSettings` uses for the capture path.
struct FeedbackSettings: Equatable, Sendable {
    var soundEffectsEnabled: Bool
    var hapticFeedbackEnabled: Bool
    var soundEffectChoice: SoundEffectChoice

    /// Everything off: the default for tests and previews, where a cue must stay inert.
    static let silent = FeedbackSettings(
        soundEffectsEnabled: false,
        hapticFeedbackEnabled: false,
        soundEffectChoice: .defaultChoice
    )
}
