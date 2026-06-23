import AppKit

@MainActor
enum Sounds {
    private static var cachedSounds: [SoundResource: NSSound] = [:]

    static func play(_ cue: HapticCue) {
        guard SettingsManager.shared.soundEffectsEnabled else { return }
        play(cue, choice: SettingsManager.shared.soundEffectChoice)
    }

    static func preview(_ choice: SoundEffectChoice) {
        play(.capture, choice: choice)
    }

    private static func play(_ cue: HapticCue, choice: SoundEffectChoice) {
        guard let sound = sound(for: cue, choice: choice) else { return }
        sound.stop()
        sound.currentTime = 0
        sound.play()
    }

    private static func sound(for cue: HapticCue, choice: SoundEffectChoice) -> NSSound? {
        switch cue {
        case .capture: sound(for: choice.captureSound)
        case .paste: sound(for: choice.pasteSound)
        case .pin, .delete: nil
        }
    }

    private static func sound(for resource: SoundResource) -> NSSound? {
        if let cached = cachedSounds[resource] { return cached }
        guard let sound = load(resource) else { return nil }
        sound.volume = 0.35
        cachedSounds[resource] = sound
        return sound
    }

    private static func load(_ resource: SoundResource) -> NSSound? {
        switch resource {
        case .system(let name):
            return NSSound(named: NSSound.Name(name))
        case .asset(let name):
            guard let data = NSDataAsset(name: name)?.data else { return nil }
            return NSSound(data: data)
        }
    }
}

private enum SoundResource: Hashable {
    case system(String)
    case asset(String)
}

private extension SoundEffectChoice {
    var captureSound: SoundResource {
        switch self {
        case .system: .system("Tink")
        case .tick: .asset("YankSoundTickCapture")
        case .click: .asset("YankSoundClickCapture")
        case .select: .asset("YankSoundSelectCapture")
        }
    }

    var pasteSound: SoundResource {
        switch self {
        case .system: .system("Pop")
        case .tick: .asset("YankSoundTickPaste")
        case .click: .asset("YankSoundClickPaste")
        case .select: .asset("YankSoundSelectPaste")
        }
    }
}
