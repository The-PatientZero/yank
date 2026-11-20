import Testing
@testable import YankCore

@Suite struct HapticCueTests {

    @Test("discrete confirmations use the generic pattern")
    func confirmationsAreGeneric() {
        #expect(HapticCue.capture.pattern == .generic)
        #expect(HapticCue.paste.pattern == .generic)
        #expect(HapticCue.delete.pattern == .generic)
    }

    @Test("snap-into-place actions use the alignment pattern")
    func snapsAreAlignment() {
        #expect(HapticCue.pin.pattern == .alignment)
    }

    @Test("every cue resolves to a pattern (no unmapped case)")
    func everyCueMaps() {
        for cue in HapticCue.allCases {
            // Exhaustive `switch` in `pattern` guarantees totality at compile time; this
            // asserts the set is non-empty and each call is total at runtime too.
            _ = cue.pattern
        }
        #expect(HapticCue.allCases.count == 4)
    }
}
