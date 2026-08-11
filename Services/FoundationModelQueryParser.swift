import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Parses a natural-language search phrase into a structured `SmartQuery` on-device
/// (macOS 26+). Falls back to treating the whole phrase as literal keywords when the model
/// is unavailable or fails, so search always returns something sensible.
struct FoundationModelQueryParser: QueryParser {
    func parse(_ phrase: String) async -> SmartQuery {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let plan = try await session.respond(to: phrase, generating: SmartQueryPlan.self).content
                return SmartQuery(
                    keywords: plan.keywords.trimmingCharacters(in: .whitespacesAndNewlines),
                    app: plan.app.isEmpty ? nil : plan.app,
                    sinceDays: plan.days > 0 ? plan.days : nil,
                    type: Self.type(from: plan.kind)
                )
            } catch {
                return SmartQuery(keywords: phrase)
            }
        }
        #endif
        return SmartQuery(keywords: phrase)
    }

    /// Maps the model's free-text `kind` onto the domain type. Internal rather than private
    /// because it is the one part of this parser that is our decision, not the model's, and
    /// an unrecognised kind must fall back to "no type filter" rather than guessing.
    static func type(from kind: String) -> ClipboardItemType? {
        switch kind.lowercased() {
        case "image", "images", "picture", "screenshot": return .image
        case "text": return .text
        default: return nil
        }
    }

    private static let instructions = """
    Convert the user's clip-search request into structured fields. Extract the essential search \
    keywords, dropping filler like "the clip I copied". If an app is mentioned set app, else "". \
    If a time like "yesterday" or "last week" is mentioned set days to the number of days back, \
    else 0. Set kind to "image", "text", or "any".
    """
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct SmartQueryPlan {
    @Guide(description: "essential search keywords, filler words removed")
    var keywords: String
    @Guide(description: "app name if one is mentioned, otherwise empty")
    var app: String
    @Guide(description: "number of days back if a time is mentioned, otherwise 0")
    var days: Int
    @Guide(description: "content kind: image, text, or any")
    var kind: String
}
#endif
