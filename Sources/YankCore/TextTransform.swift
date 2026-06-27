import Foundation

/// A one-shot, on-device rewrite applied to a clip's text before pasting (Smart Paste).
/// User-invoked, never automatic; the result is pasted, never stored.
public enum TextTransform: String, CaseIterable, Identifiable, Sendable {
    case proofread, concise, formal, casual, summarize, bullets

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .proofread: return "Proofread"
        case .concise:   return "Make concise"
        case .formal:    return "Formal tone"
        case .casual:    return "Casual tone"
        case .summarize: return "Summarize"
        case .bullets:   return "Bulleted list"
        }
    }

    public var symbol: String {
        switch self {
        case .proofread: return "checkmark.circle"
        case .concise:   return "scissors"
        case .formal:    return "briefcase"
        case .casual:    return "face.smiling"
        case .summarize: return "text.line.first.and.arrowtriangle.forward"
        case .bullets:   return "list.bullet"
        }
    }

    /// Model instruction. Each ends by constraining output to the result only, so the paste
    /// is clean — no preamble, no quotes.
    public var instruction: String {
        switch self {
        case .proofread:
            return "Proofread the text: fix spelling, grammar, and punctuation without changing meaning or formatting. Return only the corrected text."
        case .concise:
            return "Rewrite the text to be clearer and more concise while preserving meaning. Return only the rewritten text."
        case .formal:
            return "Rewrite the text in a more formal, professional tone. Return only the rewritten text."
        case .casual:
            return "Rewrite the text in a friendlier, more casual tone. Return only the rewritten text."
        case .summarize:
            return "Summarize the key points of the text concisely. Return only the summary."
        case .bullets:
            return "Rewrite the text as a clear, concise bulleted list. Return only the list."
        }
    }
}

/// Applies a `TextTransform` to text on-device. Implemented by the Foundation Models
/// transformer on macOS 26+; the protocol stays framework-free for testability.
public protocol TextTransformer: Sendable {
    func transform(_ text: String, as transform: TextTransform) async -> String?
}
