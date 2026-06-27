import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device text rewriter backed by Foundation Models (macOS 26+). Returns nil when the
/// model can't run or the rewrite fails, so callers fall back to pasting the original text.
struct FoundationModelTransformer: TextTransformer {
    func transform(_ text: String, as transform: TextTransform) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: transform.instruction)
                let response = try await session.respond(to: String(text.prefix(6000)))
                let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return output.isEmpty ? nil : output
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
