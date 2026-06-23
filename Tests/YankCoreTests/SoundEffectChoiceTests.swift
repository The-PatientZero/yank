import Testing
@testable import YankCore

@Suite struct SoundEffectChoiceTests {
    @Test func defaultChoicePreservesCurrentSound() {
        #expect(SoundEffectChoice.defaultChoice == .system)
    }

    @Test func rawValuesAreStableForStoredPreferences() {
        #expect(SoundEffectChoice.allCases.map(\.rawValue) == [
            "system",
            "tick",
            "click",
            "select"
        ])
    }
}
