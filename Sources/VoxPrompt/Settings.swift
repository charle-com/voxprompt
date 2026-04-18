import Foundation

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let hotkey = "hotkey.binding"
        static let model = "whisper.model"
        static let language = "whisper.language"
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
