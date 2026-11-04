import Foundation
import UniformTypeIdentifiers

/// The pasteboard generation iOS has already decided on, persisted so an unchanged clipboard is
/// not captured again after the process is killed. `changeCount` restarts at a reboot, so the
/// record also carries the device boot time: a count only matches inside the same boot.
struct PasteboardAcknowledgement: Codable, Equatable, Sendable {
    /// App Group defaults key. Older builds ignore it.
    static let defaultsKey = "iosPasteboardAcknowledgement"

    /// Tolerance when comparing boot times, so a small clock adjustment is not read as a reboot.
    /// A false "new boot" only costs one repeated capture, never a lost one.
    static let bootTimeTolerance: TimeInterval = 60

    /// Pre-UTI pasteboard string type that `UIPasteboard.string` still honours.
    private static let legacyStringType = "NSStringPboardType"

    let changeCount: Int
    let bootTime: Date

    func covers(changeCount currentChangeCount: Int, bootTime currentBootTime: Date) -> Bool {
        changeCount == currentChangeCount
            && abs(bootTime.timeIntervalSince(currentBootTime)) <= Self.bootTimeTolerance
    }

    /// Whether any declared pasteboard type is text. Decided from the type list alone, which
    /// iOS lets an app read without a paste prompt, so a clipboard with no text (an image or a
    /// file) is never read. An empty list has no text.
    static func hasTextRepresentation(in pasteboardTypes: [String]) -> Bool {
        pasteboardTypes.contains { type in
            type == legacyStringType || UTType(type)?.conforms(to: .text) == true
        }
    }

    /// Whether the clipboard should be saved as an image: it declares an image type and no plain
    /// text. Plain text wins, as on the Mac, so copied text that carries a picture stays text,
    /// while an image that comes with only HTML or RTF (a copy from a web page) is saved as the image.
    static func prefersImage(in pasteboardTypes: [String]) -> Bool {
        let declaresImage = pasteboardTypes.contains { UTType($0)?.conforms(to: .image) == true }
        let declaresPlainText = pasteboardTypes.contains { type in
            type == legacyStringType || UTType(type)?.conforms(to: .plainText) == true
        }
        return declaresImage && !declaresPlainText
    }
}

/// Reads and writes the persisted acknowledgement. Without a readable boot time nothing is
/// recorded and nothing matches, so the failure mode is one repeated capture, never a lost one.
struct PasteboardAcknowledgementStore {
    private let defaults: UserDefaults
    private let readBootTime: () -> Date?

    init(defaults: UserDefaults, readBootTime: @escaping () -> Date?) {
        self.defaults = defaults
        self.readBootTime = readBootTime
    }

    func isAcknowledged(changeCount: Int) -> Bool {
        guard let bootTime = readBootTime(),
              let data = defaults.data(forKey: PasteboardAcknowledgement.defaultsKey),
              let record = try? JSONDecoder().decode(PasteboardAcknowledgement.self, from: data)
        else {
            return false
        }
        return record.covers(changeCount: changeCount, bootTime: bootTime)
    }

    func record(changeCount: Int) throws {
        guard let bootTime = readBootTime() else { return }
        let record = PasteboardAcknowledgement(changeCount: changeCount, bootTime: bootTime)
        defaults.set(try JSONEncoder().encode(record), forKey: PasteboardAcknowledgement.defaultsKey)
    }
}
