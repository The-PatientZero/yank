import Carbon
import Testing
@testable import Yank

@Suite("Carbon modifier mask")
struct HotkeyRegistryTests {
    @Test("No modifiers produce an empty mask")
    func emptyMask() {
        let mask = HotkeyRegistry.carbonModifierMask(
            for: HotkeyModifiers(shift: false, command: false, option: false, control: false)
        )

        #expect(mask == 0)
    }

    @Test("Each modifier maps to its own Carbon bit")
    func eachModifierMapsToItsOwnBit() {
        func mask(shift: Bool = false, command: Bool = false,
                  option: Bool = false, control: Bool = false) -> UInt32 {
            HotkeyRegistry.carbonModifierMask(
                for: HotkeyModifiers(shift: shift, command: command, option: option, control: control)
            )
        }

        #expect(mask(shift: true) == UInt32(shiftKey))
        #expect(mask(command: true) == UInt32(cmdKey))
        #expect(mask(option: true) == UInt32(optionKey))
        #expect(mask(control: true) == UInt32(controlKey))
    }

    /// The bits must be independent: a combination is the union, never a replacement. The
    /// app's default shortcut is ⇧⌘V, so that combination in particular has to survive.
    @Test("Modifiers combine rather than overwrite one another")
    func modifiersCombine() {
        let shiftCommand = HotkeyRegistry.carbonModifierMask(
            for: HotkeyModifiers(shift: true, command: true, option: false, control: false)
        )
        #expect(shiftCommand == UInt32(shiftKey) | UInt32(cmdKey))

        let all = HotkeyRegistry.carbonModifierMask(
            for: HotkeyModifiers(shift: true, command: true, option: true, control: true)
        )
        #expect(all == UInt32(shiftKey) | UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey))
        #expect(all & UInt32(shiftKey) != 0)
        #expect(all & UInt32(cmdKey) != 0)
        #expect(all & UInt32(optionKey) != 0)
        #expect(all & UInt32(controlKey) != 0)
    }
}

@Suite("Smart query kind mapping")
struct FoundationModelQueryParserTests {
    @Test("Recognised image words select the image type")
    func imageKinds() {
        for kind in ["image", "images", "picture", "screenshot"] {
            #expect(FoundationModelQueryParser.type(from: kind) == .image, "\(kind) did not map")
        }
    }

    @Test("Text maps to the text type")
    func textKind() {
        #expect(FoundationModelQueryParser.type(from: "text") == .text)
    }

    @Test("Kind matching ignores case and surrounding model formatting")
    func kindMatchingIgnoresCase() {
        #expect(FoundationModelQueryParser.type(from: "Image") == .image)
        #expect(FoundationModelQueryParser.type(from: "SCREENSHOT") == .image)
        #expect(FoundationModelQueryParser.type(from: "Text") == .text)
    }

    /// An unrecognised kind must widen the search, not narrow it to a guess — the model is
    /// free-text and "any" is its documented catch-all.
    @Test("An unrecognised kind applies no type filter")
    func unrecognisedKindAppliesNoFilter() {
        for kind in ["any", "", "video", "pdf", "clipboard", "🙂"] {
            #expect(FoundationModelQueryParser.type(from: kind) == nil, "\(kind) narrowed the search")
        }
    }
}
