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

/// The single fire-and-forget feedback layer. A call site emits a *semantic* cue — `capture`,
/// `paste`, `pin`, … — and this fans it out to every non-visual channel (tactile now, audible too
/// once enabled). Each channel self-gates on its own user setting, so emitting a cue is always safe
/// and stays silent when the user has everything off.
///
/// View-layer animation is deliberately *not* here: it must run where the view lives (it observes
/// state, it can't be fired from a store or controller). Animation composes with these cues at the
/// view, not through this facade.
@MainActor
enum Feedback {
    static func emit(_ cue: HapticCue, allowsSound: Bool = true) {
        Haptics.fire(cue)
        if allowsSound {
            Sounds.play(cue)
        }
    }
}
