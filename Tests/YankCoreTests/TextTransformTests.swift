import Testing
@testable import YankCore

@Suite struct TextTransformTests {

    @Test func everyCaseIsFullyDescribed() {
        for transform in TextTransform.allCases {
            #expect(!transform.label.isEmpty)
            #expect(!transform.symbol.isEmpty)
            #expect(transform.instruction.count > 20)
        }
    }

    @Test func instructionsConstrainOutputToResultOnly() {
        // Each instruction must tell the model to return only the result, so the paste is clean.
        for transform in TextTransform.allCases {
            #expect(transform.instruction.lowercased().contains("return only"))
        }
    }
}
