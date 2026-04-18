# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-18

First public release.

### Added
- On-device voice transcription via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) on the Apple Neural Engine
- Global press-and-hold hotkey (Right Option by default), configurable in Preferences
- Live waveform HUD shown at the bottom of the screen during recording
- Custom glossary with Levenshtein fuzzy-match for proper nouns and jargon
- Menu bar popover UI (light theme) with clean typography and iris accent
- Multilingual support: French / English auto-detect
- Persistent signing setup (`setup-signing.sh`) so macOS TCC keeps the Accessibility grant across rebuilds
- DMG packager (`package-dmg.sh`) for distribution
- Icon generator (`make-icon.swift`) producing `AppIcon.icns` from code

### Security
- File logger disabled by default; when enabled via `VOXPROMPT_DEBUG=1`, logs are written to `~/Library/Logs/VoxPrompt/voxprompt.log` with mode `0600` (user-only) instead of `/tmp`
