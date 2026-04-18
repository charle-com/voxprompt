# Privacy Policy

**TL;DR: VoxPrompt runs entirely on your Mac. Your voice and your text never leave the device.**

## What VoxPrompt does with your data

| Data | Stored where | For how long | Shared with anyone? |
|------|--------------|--------------|---------------------|
| Audio recording | Temporary WAV file in your OS temp folder | Deleted immediately after transcription | No |
| Transcribed text | Clipboard (standard macOS paste) | Until you copy something else | No |
| Glossary | macOS UserDefaults for `fr.charlesneveu.voxprompt` | Until you delete it | No |
| Hotkey preference | macOS UserDefaults for `fr.charlesneveu.voxprompt` | Until you change it | No |
| Debug log (off by default) | `~/Library/Logs/VoxPrompt/voxprompt.log`, mode `0600` | Until you delete it | No |

## Network activity

VoxPrompt makes **one type of network call** in its entire lifecycle:

- **First-time model download**: on first use (or when you switch models in Preferences), WhisperKit downloads the selected Whisper model weights from HuggingFace (`huggingface.co/argmaxinc/whisperkit-coreml`). The model is cached locally and subsequent launches require no internet.

No other network calls. No analytics, no telemetry, no crash reports, no check-for-updates ping, no third-party SDK calls.

## Third-party dependencies

VoxPrompt depends on [`argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit), which in turn depends on `swift-transformers` for tokenization. Both are open-source and audited. Neither sends data anywhere from within VoxPrompt.

## Permissions

| Permission | What VoxPrompt does with it |
|------------|-----------------------------|
| Microphone | Records audio during press-and-hold only. The recording stops when you release the key. |
| Accessibility | Captures the global hotkey and simulates ⌘V to paste the transcribed text into the active app. VoxPrompt does not log keystrokes, observe other apps, or read other apps' content. |

## Logs

Logging is **disabled by default**. If you enable it (`launchctl setenv VOXPROMPT_DEBUG 1`), the log file contains transcriptions in plain text. Keep logging off unless you're actively debugging, and delete the log file afterwards:

```bash
rm ~/Library/Logs/VoxPrompt/voxprompt.log
```

## Questions?

Open an issue on [GitHub](https://github.com/charlesneveu/voxprompt/issues).

---

*Last updated: 2026-04-18.*
