# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-05-06

Reliability release: fixes the auto-paste path that did not consistently insert the transcribed text into the focused app. Tested on macOS 26.4.1 (Tahoe).

### Fixed

- **Auto-paste now reliably inserts the transcribed text into the focused app.** Previously, on macOS 14+ and macOS 26, the text often landed in the system pasteboard but the simulated `Cmd+V` did not reach the target window, forcing the user to paste manually.

### Added

- **Target app capture at hotkey press.** `HotkeyManager` now snapshots `NSWorkspace.shared.frontmostApplication` at the `keyDown` of the hotkey (not `keyUp`) and passes it through `onPress` and `onRelease` callbacks. This is the only reliable source of truth for "where the user intended the text to go", because frontmost can drift during the 1-2s transcription window (Notification Center popups, alerts, app switching).
- **Paste cascade in `Paster.swift`.** New strategy chain: (1) CGEvent `Cmd+V` posted directly to the target app's PID via `postToPid(_:)`, with `cgAnnotatedSessionEventTap` as a fallback when no PID is known; (2) AppleScript `tell application "System Events" to keystroke "v" using command down`, which goes through a trusted AppKit client and works on apps that reject private CGEvents; (3) optional Unicode insertion via `CGEvent.keyboardSetUnicodeString` for niche apps. Inspired by the patterns used in Pindrop (`watzon/pindrop`, `OutputManager.swift`) and VoiceInk (`Beingpax/VoiceInk`, `CursorPaster.swift`).
- **Paste mode picker in Preferences.** New "Collage" section with four modes: Auto (default, recommended cascade), AppleScript only, Unicode insertion (robust mode for apps that reject CGEvents, but breaks Terminal), and Clipboard only (no auto-paste, the user pastes manually).
- **Clipboard preservation.** The user's previous clipboard contents are saved before the transcribed text is set, then restored 250 ms after the paste. Dictation no longer destroys what the user had copied.
- **`NSAppleEventsUsageDescription`** entry added to `Info.plist`, required by macOS to allow the AppleScript fallback path. Triggers a one-time Automation prompt on first fallback.

### Changed

- **Target activation before paste.** The captured target app is now explicitly re-activated via `NSRunningApplication.activate(options: [.activateIgnoringOtherApps])` followed by an 80 ms settle delay, before the paste keystroke is sent. The macOS 14+ deprecation warning on `activateIgnoringOtherApps` is acknowledged: the new cooperative `activate()` does not work for menu bar apps with activation policy `.accessory` because they never own the focus to begin with. This is the same compromise Pindrop and VoiceInk make.
- **CGEvent transport switched.** Cmd+V is now posted via `postToPid(targetPid)` instead of `cghidEventTap`. The HID-layer tap is the lowest-level injection point and can be intercepted, reordered, or filtered by third-party keyboard utilities (Karabiner, Hammerspoon, etc.). Direct PID delivery bypasses that.
- **`HotkeyManager` callback signature.** `onPress` and `onRelease` now take an `NSRunningApplication?` payload (the captured target) instead of `Void`. Consumers (`AppDelegate`) updated accordingly.
- **HUD state ordering in `AppDelegate.stopAndTranscribe(target:)`.** The HUD switches to `.done` immediately after transcription succeeds, then awaits the paste; this prevents the HUD from looking stuck during the 80-250 ms paste window.

### Internals

- `Paster` is now `@MainActor`-isolated for its public entry point and uses `Task.detached` only for the synchronous `NSAppleScript.executeAndReturnError` call.
- Pasteboard save/restore uses the full `(NSPasteboard.PasteboardType, Data)` tuple list, not just the string representation, so rich content (RTF, image, file URLs) is preserved across dictations.

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
