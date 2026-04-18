<p align="center">
  <img src="assets/banner.png" alt="VoxPrompt — On-device voice dictation for macOS" width="100%" />
</p>

<h1 align="center">VoxPrompt</h1>

<p align="center">
  <strong>Hold a key, speak, release.</strong><br/>
  The fastest <strong>offline voice-to-text</strong> app for macOS.<br/>
  Powered by Whisper on the Apple Neural Engine. Private. Free. Open-source.
</p>

<p align="center">
  <a href="https://github.com/charlesneveu/voxprompt/releases/latest"><img src="https://img.shields.io/github/v/release/charlesneveu/voxprompt?style=flat-square&color=6E5EFF" alt="Latest release"/></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square" alt="macOS 14+"/>
  <img src="https://img.shields.io/badge/Apple_Silicon-required-black?style=flat-square" alt="Apple Silicon"/>
  <img src="https://img.shields.io/badge/Swift-5.10-orange?style=flat-square" alt="Swift"/>
  <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License MIT"/>
  <img src="https://img.shields.io/github/stars/charlesneveu/voxprompt?style=flat-square&color=yellow" alt="Stars"/>
</p>

<p align="center">
  <a href="https://github.com/charlesneveu/voxprompt/releases/latest"><strong>Download latest DMG</strong></a> ·
  <a href="#features">Features</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="README.fr.md">Français</a>
</p>

---

## What is VoxPrompt?

**VoxPrompt is a free, open-source macOS voice dictation app that runs entirely on your Mac.** Hold a key, speak, release — the text is transcribed by [Whisper](https://openai.com/research/whisper) on the Apple Neural Engine and pasted into any app. No cloud, no subscription, no account. A lightweight open-source alternative to Superwhisper, Aiko, and MacWhisper.

- **Offline** · audio never leaves your Mac
- **Fast** · ~1-second latency for a 5-second utterance
- **Private** · zero telemetry, zero tracking
- **Free** · MIT licensed, no paywall

## Features

- 🎙️ **On-device voice transcription** via WhisperKit on the Apple Neural Engine
- ⌨️ **Global press-and-hold hotkey** (Right Option by default, configurable)
- 〰️ **Live waveform HUD** with a clean capsule design
- 📚 **Custom glossary** with Levenshtein fuzzy-match for proper nouns, brand names, and technical jargon
- 🎛️ **Menu bar popover UI** with a refined light theme
- 🌍 **Multilingual** — French and English auto-detect, or force a specific language
- 📝 **Clipboard + auto-paste** into the currently focused app
- 🧠 **Swappable Whisper models** — from 39 MB Tiny to 632 MB Large v3 Turbo

## Install

### Download the DMG (recommended)

Grab the signed DMG from the [latest release](https://github.com/charlesneveu/voxprompt/releases/latest), open it, drag `VoxPrompt.app` into `/Applications`, and launch.

### Build from source

```bash
git clone https://github.com/charlesneveu/voxprompt.git
cd voxprompt
./setup-signing.sh   # one-time: creates a persistent code signing identity
./build.sh
open build/VoxPrompt.app
```

## How it works

1. **Press and hold** your configured key. A HUD appears at the bottom of the screen with a live waveform.
2. **Speak** naturally. Audio is captured at 16 kHz mono.
3. **Release**. Whisper transcribes the audio locally on the Neural Engine. The text is automatically pasted where your cursor is.

On the first run the Whisper model weights (~632 MB) are downloaded once from HuggingFace. Every subsequent run loads from the local cache.

## Permissions

VoxPrompt needs two macOS permissions. They are requested on first use:

| Permission | Why |
|------------|-----|
| **Microphone** | To capture your voice during dictation |
| **Accessibility** | To detect the global hotkey and simulate ⌘V for auto-paste |

Everything is handled by native macOS APIs. No third-party SDK has access to your audio or text.

## Whisper models

VoxPrompt uses [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) by Argmax, which runs Whisper models on the Apple Neural Engine via CoreML. Models are downloaded from [`argmaxinc/whisperkit-coreml`](https://huggingface.co/argmaxinc/whisperkit-coreml) on HuggingFace.

| Model | Size | Latency (Apple Silicon) | Quality |
|-------|------|-------------------------|---------|
| **Large v3 Turbo** (default) | 632 MB | ~1 s | Excellent, multilingual |
| Large v3 | 626 MB | ~2 s | Maximum |
| Base | 74 MB | instant | Fair |
| Tiny | 39 MB | instant | Testing only |

Switch models from the menu bar popover → Preferences. The new model downloads on first use.

## Glossary — fix Whisper's weak spot

Whisper is excellent at general speech but struggles with proper nouns (client names, brands, technical terms). VoxPrompt solves this with a local glossary.

Add words in **Preferences → Glossary** (comma or newline separated). After each transcription every word in the output is compared to your glossary using Levenshtein distance. Close phonetic matches are replaced with the correct spelling and casing.

```
Glossary: Gandy, Kwanko, Shopify, Klaviyo

Whisper hears       →  VoxPrompt outputs
"I meet Gandhi"     →  "I meet Gandy"
"send to Shopi"     →  "send to Shopify"
"call with Kwanko"  →  "call with Kwanko"  (already correct, kept)
```

## Persistent code signing

macOS invalidates Accessibility permission every time the ad-hoc signature changes (i.e. every rebuild). If you build from source frequently, run `./setup-signing.sh` once. It generates a stable self-signed "VoxPrompt Developer" identity in your login keychain. Subsequent builds reuse it, so macOS keeps the Accessibility grant.

## Debug logging

Disabled by default to protect privacy (transcribed text can contain sensitive data). Enable for troubleshooting:

```bash
launchctl setenv VOXPROMPT_DEBUG 1
```

Logs are written to `~/Library/Logs/VoxPrompt/voxprompt.log` with mode `0600` (user-only).

## Tech stack

- **Swift 5.10**, SwiftUI, AppKit
- **[WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)** — Whisper on CoreML + MLX
- **AVFoundation** — 16 kHz mono audio capture
- **NSEvent global monitor** — global hotkey
- **NSPasteboard** + **CGEvent** — paste into the active app

## Privacy

VoxPrompt is built around one simple promise: **your voice never leaves your Mac.**

- 100 % on-device transcription
- No cloud API, no server, no telemetry
- Only one network call in the lifetime of the app: downloading the Whisper model weights on first use
- No third-party SDKs, no analytics, no crash reporters

See [PRIVACY.md](PRIVACY.md) for a detailed breakdown.

## FAQ

### Is VoxPrompt really free?
Yes. MIT licensed, no paywall, no upsell, no freemium.

### How does it compare to Superwhisper / Aiko / MacWhisper?
Similar on-device approach, similar Whisper backend. VoxPrompt is fully open-source and MIT licensed.

### Does it work without an internet connection?
After the initial model download, yes — fully offline.

### Which languages are supported?
All 99 languages supported by Whisper. The default model (Large v3 Turbo) auto-detects the language. You can force a language in Preferences.

### Does it support dictation in Intel Macs?
No. VoxPrompt requires Apple Silicon (M1 / M2 / M3 / M4) because WhisperKit runs on the Apple Neural Engine.

### Can I use VoxPrompt in any app?
Yes. VoxPrompt pastes into whichever app has focus — text editors, browsers, Slack, messaging apps, terminals, you name it.

### Is the audio stored anywhere?
No. Audio is written to a temporary WAV file, transcribed, then immediately deleted.

## Roadmap

- [ ] Live waveform driven by microphone input (currently simulated)
- [ ] Custom hotkey capture (any key combo)
- [ ] Launch at login
- [ ] Menu bar icon customisation
- [ ] Streaming transcription (partial results while speaking)
- [ ] Tray toggle between auto-paste and clipboard-only
- [ ] Localised UI (EN / FR / ES / DE)

Contributions welcome — open an issue or PR.

## Related projects

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) — the brilliant Swift library that makes on-device Whisper possible (used under the hood)
- [Whisper](https://github.com/openai/whisper) — OpenAI's original speech recognition model
- [Superwhisper](https://superwhisper.com) — excellent paid alternative
- [Aiko](https://sindresorhus.com/aiko) — free local Whisper transcription for audio files

## License

[MIT](LICENSE) · Copyright © 2026 Charles Neveu

---

<p align="center">
  <sub>Built with ♥ on Apple Silicon. Star ⭐ if you find it useful!</sub>
</p>
