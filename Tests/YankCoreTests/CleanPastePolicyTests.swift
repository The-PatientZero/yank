import Foundation
import Testing
@testable import YankCore

@Suite struct CleanPastePolicyTests {
    private let terminalText = ClipboardItem.text("ls", sourceApp: "Terminal")
    private let mailText = ClipboardItem.text("hi", sourceApp: "Mail")
    private let unknownSourceText = ClipboardItem.text("hi")
    private let terminalImage = ClipboardItem.image(filename: "shot.png", sourceApp: "Terminal")

    @Test func offNeverCleans() {
        let policy = CleanPastePolicy(mode: .off, apps: ["Terminal"])
        #expect(!policy.cleansByDefault(terminalText))
        #expect(!policy.cleansByDefault(mailText))
    }

    @Test func alwaysCleansEveryTextClip() {
        let policy = CleanPastePolicy(mode: .always, apps: [])
        #expect(policy.cleansByDefault(terminalText))
        #expect(policy.cleansByDefault(mailText))
        #expect(policy.cleansByDefault(unknownSourceText))
    }

    @Test func chosenAppsCleansOnlyTextFromThoseApps() {
        let policy = CleanPastePolicy(mode: .chosenApps, apps: ["Terminal"])
        #expect(policy.cleansByDefault(terminalText))
        #expect(!policy.cleansByDefault(mailText))
        #expect(!policy.cleansByDefault(unknownSourceText))
    }

    @Test func chosenAppsMatchesTheExactName() {
        let policy = CleanPastePolicy(mode: .chosenApps, apps: ["terminal"])
        #expect(!policy.cleansByDefault(terminalText))
    }

    @Test func imagesAreNeverCleaned() {
        for mode in CleanPasteMode.allCases {
            let policy = CleanPastePolicy(mode: mode, apps: ["Terminal"])
            #expect(!policy.cleansByDefault(terminalImage))
        }
    }

    @Test func everyModeHasALabel() {
        #expect(CleanPasteMode.allCases.map(\.label) == ["Off", "From chosen apps", "Always"])
    }

    @Test func theDefaultPolicyIsOff() {
        let policy = CleanPastePolicy()
        #expect(policy.mode == .off)
        #expect(policy.apps.isEmpty)
    }
}
