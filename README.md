# VoxPrompt

**Hold a key, speak, release.** On-device voice dictation for macOS, powered by [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) on the Apple Neural Engine. Fully offline, private, free. A lightweight alternative to Superwhisper.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![Swift](https://img.shields.io/badge/Swift-5.10-orange) ![License MIT](https://img.shields.io/badge/license-MIT-blue)

*[Version française](README.fr.md)*

## Features

- **On-device transcription** with Whisper (no network calls except initial model download)
- **Global hotkey** press-and-hold (Right Option by default, configurable)
- **Live waveform HUD** while recording
- **Custom glossary** with fuzzy-match Levenshtein correction for proper nouns and jargon
- **Menu bar popover** with a clean, minimal light theme
- **Multilingual** (French/English auto-detect or forced)
- **No telemetry**, no tracking, no analytics

## Install

### From DMG
```bash
./build.sh && ./package-dmg.sh
open build/VoxPrompt.dmg
```
Drag `VoxPrompt.app` into `/Applications`.

### Build and run directly
```bash
./build.sh
open build/VoxPrompt.app
```

## Persistent signing (recommended)

By default macOS invalidates the Accessibility permission on every rebuild (new ad-hoc signature). To keep the grant across builds, create a stable self-signed code signing identity:

```bash
./setup-signing.sh
```

The script generates a "VoxPrompt Developer" identity in your login keychain. Subsequent builds will pick it up automatically.

## Permissions

1. **Microphone**: system popup on first recording
2. **Accessibility**: System Settings → Privacy & Security → Accessibility → add VoxPrompt
   (required to capture the global hotkey and simulate ⌘V)

## Whisper models

Downloaded automatically from [huggingface.co/argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) on first use. Selectable from Preferences.

| Model | Size | Latency | Quality |
|-------|------|---------|---------|
| Large v3 Turbo (default) | 632 MB | ~1 s | Excellent, multilingual |
| Large v3 | 626 MB | ~2 s | Maximum |
| Base | 74 MB | instant | Fair |
| Tiny | 39 MB | instant | Testing only |

## Glossary

Add proper nouns, brands, or technical terms in **Preferences → Glossary** (comma or newline separated). After each transcription, every word is compared against your glossary using Levenshtein distance. Close phonetic matches are replaced with the glossary spelling.

Example: with `Gandy` in the glossary → `"I meet Gandhi tomorrow"` becomes `"I meet Gandy tomorrow"`.

## Debug

The file logger is disabled by default. To enable:
```bash
launchctl setenv VOXPROMPT_DEBUG 1
```
Logs are written to `~/Library/Logs/VoxPrompt/voxprompt.log` with `0600` permissions (user-only).

## Stack

- Swift 5.10+, SwiftUI, AppKit
- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (CoreML + MLX)
- AVFoundation (16 kHz mono audio capture)
- NSEvent global monitor (hotkey)
- NSPasteboard + CGEvent (paste)

## Privacy

- **100 % on-device**: audio, transcription, and clipboard never leave your Mac
- Only network call: initial Whisper model download (one-time)
- Zero telemetry, trackers, or analytics

## License

[MIT](LICENSE) · Copyright © 2026 Charles Neveu
