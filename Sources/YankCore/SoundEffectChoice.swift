import Foundation

enum SoundEffectChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case tick
    case click
    case select

    static let defaultChoice: SoundEffectChoice = .system

    var id: String { rawValue }
}
