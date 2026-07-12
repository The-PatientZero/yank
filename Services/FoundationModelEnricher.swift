import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device tag suggester backed by Apple's Foundation Models (macOS 26+). Returns
/// an empty `ClipEnrichment` whenever the model can't run (older OS, Apple Intelligence off,
/// model not ready), so callers degrade silently — never an error path.
struct FoundationModelEnricher: ClipEnricher {
    /// Whether on-device suggestions can run right now. Drives hiding the opt-in toggle so
    /// the UI never offers a control that would do nothing.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            return true
        }
        #endif
        return false
    }

    func enrich(_ text: String) async -> ClipEnrichment {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(to: String(text.prefix(2000)),
                                                          generating: ClipDigest.self)
                return ClipEnrichment(tags: response.content.tags)
            } catch {
                return ClipEnrichment()
            }
        }
        #endif
        return ClipEnrichment()
    }

    static let instructions = """
    Classify clipboard text. Produce 1 to 3 short, lowercase, single-word topical tags \
    (for example: invoice, swift, address), preferring the subject over the format.
    """
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct ClipDigest {
    @Guide(description: "1 to 3 short lowercase single-word topic tags")
    var tags: [String]
}
#endif
