# Privacy Policy

**TL;DR: VoxPrompt runs entirely on your Mac. Your voice and your text never leave the device.**

## What VoxPrompt does with your data

| Data | Stored where | For how long | Shared with anyone? |
|------|--------------|--------------|---------------------|
| Audio recording | Temporary WAV file in your OS temp folder | Deleted immediately after transcription | No |
| Transcribed text | Clipboard (standard macOS paste) | Until you copy something else | No |
| Glossary | macOS UserDefaults for `fr.charlesneveu.voxprompt` | Until you delete it | No |
| Preferences (hotkey, model, microphone, paste mode) | macOS UserDefaults for `fr.charlesneveu.voxprompt` | Until you change them | No |
| Debug log (off by default) | `~/Library/Logs/VoxPrompt/voxprompt.log`, mode `0600` | Until you delete it | No |

## Network activity

VoxPrompt makes **two types of network call**, both under your control, and neither carries any of your content:

- **Model download**, on first use and whenever you switch models in Preferences. WhisperKit downloads the selected Whisper model weights from HuggingFace (`huggingface.co/argmaxinc/whisperkit-coreml`). The model is cached locally and subsequent launches need no internet at all.
- **Update check**, which is **disabled by default**. If you turn it on in Preferences, VoxPrompt asks `api.github.com` at most once a day whether a newer release exists, and opens the release page in your browser if so. The request carries nothing but a `VoxPrompt/<version>` user agent: no identifier, no usage data, no audio, no text. Nothing is downloaded or installed automatically.

No other network calls. No analytics, no telemetry, no crash reports, no third-party SDK calls.

## Third-party dependencies

VoxPrompt depends on [`argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit), which in turn depends on `swift-transformers` for tokenization. Both are open-source and audited. Neither sends data anywhere from within VoxPrompt.

## Permissions

| Permission | What VoxPrompt does with it |
|------------|-----------------------------|
| Microphone | Records audio while you hold the hotkey, and only then. No audio device is even opened until you press the key, and everything is released as soon as you let go. |
| Accessibility | Captures the global hotkey and simulates ⌘V to paste the transcribed text into the active app. VoxPrompt does not log keystrokes, observe other apps, or read other apps' content. |
| Automation (optional) | Only ever used to ask System Events to perform a paste, as a fallback for apps that ignore synthetic key events. Nothing else is scripted, and nothing is read back. |

## Clipboard handling

Pasting goes through the clipboard, so VoxPrompt saves what was there, puts the transcript in, triggers the paste, then restores your previous content. Two safeguards apply: the restore is skipped if you copied something yourself in the meantime, and content marked as concealed by a password manager is never restored, so it cannot be resurrected by VoxPrompt after the manager cleared it.

## Logs

Logging is **disabled by default**. If you enable it (`launchctl setenv VOXPROMPT_DEBUG 1`), the log file contains transcriptions in plain text. Keep logging off unless you are actively debugging, and delete the log file afterwards:

```bash
rm ~/Library/Logs/VoxPrompt/voxprompt.log
```

## Questions?

Open an issue on [GitHub](https://github.com/charle-com/voxprompt/issues).

---

*Last updated: 2026-08-20.*
