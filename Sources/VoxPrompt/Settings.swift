import Foundation

enum PasteMode: String, CaseIterable, Codable, Hashable {
    case auto             // CGEvent Cmd+V → AppleScript fallback (recommandé)
    case appleScriptOnly  // AppleScript uniquement (System Events keystroke V)
    case unicode          // Insertion Unicode directe sans clipboard (mode robuste, casse Terminal)
    case clipboardOnly    // Aucun paste auto, l'utilisateur fait Cmd+V manuel

    var label: String {
        switch self {
        case .auto: return "Auto (recommande)"
        case .appleScriptOnly: return "AppleScript uniquement"
        case .unicode: return "Insertion Unicode (robuste)"
        case .clipboardOnly: return "Presse-papier uniquement"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let hotkey = "hotkey.binding"
        static let model = "whisper.model"
        static let language = "whisper.language"
        static let pasteMode = "paste.mode"
        static let preferredInputUID = "audio.preferredInputUID"
    }

    /// UID CoreAudio du device d'entree a forcer. nil = default systeme.
    /// Defaut : `BuiltInMicrophoneDevice` pour eviter que le default systeme glisse
    /// sur Teams Loopback / BlackHole / iPhone Continuity (cause de captures muettes).
    var preferredInputUID: String? {
        get {
            if let v = defaults.object(forKey: Keys.preferredInputUID) as? String {
                return v.isEmpty ? nil : v
            }
            return "BuiltInMicrophoneDevice"
        }
        set { defaults.set(newValue ?? "", forKey: Keys.preferredInputUID) }
    }

    /// Langue forcée pour Whisper (code ISO: "fr", "en", ...). `nil` = auto-detect.
    var language: String? {
        get { defaults.string(forKey: Keys.language) ?? "fr" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    /// Glossaire : noms propres, marques, jargon. Injecté comme initial prompt Whisper.
    var glossary: String {
        get { defaults.string(forKey: "whisper.glossary") ?? "" }
        set { defaults.set(newValue, forKey: "whisper.glossary") }
    }

    var hotkey: HotkeyBinding {
        get {
            guard
                let data = defaults.data(forKey: Keys.hotkey),
                let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data)
            else { return .defaultBinding }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Keys.hotkey)
        }
    }

    /// Identifiant du modèle WhisperKit. Liste : https://huggingface.co/argmaxinc/whisperkit-coreml
    var modelIdentifier: String {
        get { defaults.string(forKey: Keys.model) ?? "openai_whisper-large-v3-v20240930_turbo_632MB" }
        set { defaults.set(newValue, forKey: Keys.model) }
    }

    /// Stratégie de paste après transcription. Default : auto (cascade CGEvent → AppleScript).
    var pasteMode: PasteMode {
        get {
            guard let raw = defaults.string(forKey: Keys.pasteMode),
                  let mode = PasteMode(rawValue: raw) else { return .auto }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.pasteMode) }
    }
}

enum ModelCatalog {
    struct Entry: Hashable {
        let identifier: String
        let label: String
    }

    static let entries: [Entry] = [
        Entry(identifier: "openai_whisper-large-v3-v20240930_turbo_632MB", label: "Large v3 Turbo (632 Mo, recommandé)"),
        Entry(identifier: "openai_whisper-large-v3-v20240930_626MB", label: "Large v3 (626 Mo, qualité max)"),
        Entry(identifier: "openai_whisper-base", label: "Base (74 Mo, rapide, qualité moyenne)"),
        Entry(identifier: "openai_whisper-tiny", label: "Tiny (39 Mo, test uniquement)"),
    ]
}
