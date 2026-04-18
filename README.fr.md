# VoxPrompt

App macOS menu bar de dictée vocale **100 % locale**. Maintiens une touche, parle, relâche : le texte est transcrit par WhisperKit sur le Neural Engine et collé dans l'app active. Inspirée de Superwhisper, offline et gratuite.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![License](https://img.shields.io/badge/license-MIT-blue)

## Fonctionnalités

- Transcription locale Whisper (aucun envoi réseau sauf téléchargement du modèle au premier lancement)
- Raccourci global (Right Option par défaut, configurable)
- HUD flottant avec waveform temps réel
- Glossaire de noms propres / jargon avec correction fuzzy-match
- Menu bar popover épuré, thème clair
- Support multilingue (FR/EN auto ou forcé)

## Installation

### Via DMG
```bash
./build.sh && ./package-dmg.sh
open build/VoxPrompt.dmg
```
Glisser `VoxPrompt.app` dans `/Applications`.

### Build et run direct
```bash
./build.sh
open build/VoxPrompt.app
```

## Signature persistante (recommandé)

Par défaut macOS invalide l'autorisation Accessibility à chaque rebuild (nouvelle signature ad-hoc). Pour garder l'autorisation entre les builds, crée une identité de code signing persistante :

```bash
./setup-signing.sh
```

Le script génère une identité auto-signée "VoxPrompt Developer" dans ton trousseau. Les builds suivants l'utiliseront automatiquement.

## Permissions

1. **Microphone** : popup automatique au premier enregistrement
2. **Accessibilité** : Réglages → Confidentialité et sécurité → Accessibilité → ajouter VoxPrompt
   (nécessaire pour capter la touche globale et simuler Cmd+V)

## Modèles Whisper

Téléchargés automatiquement depuis [huggingface.co/argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml). Choix dans les Préférences.

| Modèle | Taille | Latence | Qualité |
|--------|--------|---------|---------|
| Large v3 Turbo (défaut) | 632 Mo | ~1 s | Excellente, multilingue |
| Large v3 | 626 Mo | ~2 s | Max |
| Base | 74 Mo | instant | Moyenne |
| Tiny | 39 Mo | instant | Test uniquement |

## Glossaire

Les noms propres, marques ou termes techniques mal reconnus par Whisper peuvent être ajoutés dans **Préférences → Glossaire** (séparés par virgule ou retour ligne).

Après chaque transcription, chaque mot du texte est comparé en distance de Levenshtein à chaque item du glossaire. Les correspondances phonétiques proches sont remplacées par la version du glossaire (avec la bonne casse).

Exemple : glossaire `Gandy` → `"Je vois Gandhi demain"` devient `"Je vois Gandy demain"`.

## Debug

Logger fichier désactivé par défaut. Pour l'activer :
```bash
launchctl setenv VOXPROMPT_DEBUG 1
```
Les logs vont dans `~/Library/Logs/VoxPrompt/voxprompt.log` (perms 0600).

## Stack

- Swift 5.10+, SwiftUI, AppKit
- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (CoreML + MLX)
- AVFoundation (capture audio 16 kHz mono)
- NSEvent global monitor (hotkey)
- NSPasteboard + CGEvent (paste)

## Privacy

- **100 % local** : aucune transcription, audio ou texte n'est envoyé nulle part
- Seul appel réseau : téléchargement du modèle Whisper au premier usage
- Aucune télémétrie, aucun tracker, aucun analytics

## License

[MIT](LICENSE)
