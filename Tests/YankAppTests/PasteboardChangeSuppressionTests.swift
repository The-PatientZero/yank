import Testing
@testable import Yank

@Suite("Pasteboard Change Suppression")
struct PasteboardChangeSuppressionTests {
    @Test("Registered generation is suppressed exactly once")
    func registeredGenerationIsSuppressedExactlyOnce() {
        var suppression = PasteboardChangeSuppression()

        suppression.register(42)
        let firstObservation = suppression.shouldSuppress(42)
        let secondObservation = suppression.shouldSuppress(42)

        #expect(firstObservation)
        #expect(!secondObservation)
    }

    @Test("A later unrelated generation is not suppressed")
    func laterUnrelatedGenerationIsNotSuppressed() {
        var suppression = PasteboardChangeSuppression()

        suppression.register(42)
        let laterObservation = suppression.shouldSuppress(43)
        let staleObservation = suppression.shouldSuppress(42)

        #expect(!laterObservation)
        #expect(!staleObservation)
    }

    @Test("Observing a generation prunes older registrations")
    func observingGenerationPrunesOlderRegistrations() {
        var suppression = PasteboardChangeSuppression()
        suppression.register(41)
        suppression.register(42)
        let currentObservation = suppression.shouldSuppress(42)
        let staleObservation = suppression.shouldSuppress(41)

        #expect(currentObservation)
        #expect(!staleObservation)
    }
}
