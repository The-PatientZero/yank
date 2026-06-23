import Foundation

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
    static func emit(_ cue: HapticCue) {
        Haptics.fire(cue)
        Sounds.play(cue)
    }
}
