# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.4] - 2026-05-19

Reliability release: fixes two issues surfaced after upgrading to macOS 26.5. First, the very first dictation right after a Mac boot would frequently fail with a generic "Mic KO" HUD until the app was relaunched. Second, the Whisper decoder could enter an infinite token-repetition loop on the Turbo model, leaving the HUD spinning forever.

### Fixed

- **Cold-start "Mic KO" right after boot.** At boot, the CoreAudio HAL daemon and TCC subsystem take a moment to settle. The first `AVAudioEngine.start()` after launch-at-login would race that warmup window and fail with an opaque `OSStatus`, leaving the engine in a broken state until the app was relaunched manually. VoxPrompt now arms the input audio unit off the main thread ~600 ms after launch (one start/stop cycle through `engine.prepare()` + `engine.start()` + `engine.stop()`), so the first user hotkey runs against an already-warm unit. If the start still throws, the engine is rebuilt and the call is retried once after a 250 ms delay.
- **Whisper decoder loops on Turbo (macOS 26.x).** At `temperature: 0.0` with `withoutTimestamps: false`, the greedy decoder has no escape hatch when it falls into a token-repetition cycle — the HUD then stays in "transcribing" forever. The `DecodingOptions` now follow the standard Whisper anti-loop recipe: `withoutTimestamps: true`, explicit `temperatureFallbackCount: 3`, `compressionRatioThreshold: 2.4`, `logProbThreshold: -1.0`, `noSpeechThreshold: 0.6`. The decoder now retries the segment at a higher temperature whenever the output compresses too well (signature of repeated tokens) or the average log-probability collapses.

### Changed

- **HUD error message disambiguation.** The generic "Mic KO" was previously shown for every recording-start failure, including transient HAL-not-ready conditions at boot. The HUD now distinguishes the two: "Audio non prêt, réessaye" for cold-start `OSStatus` failures (the user should just hold the hotkey again), versus "Mic KO" only for permission/device-missing failures (the user needs to act).

### Internals

- `AudioRecorder.engine` is now `var` (was `let`), so it can be replaced when a cold-start failure puts the input unit in an undefined state. `rebuildEngine()` drops the tap, stops the engine, and instantiates a fresh `AVAudioEngine()`; `start()` calls it in its `catch` branch before retrying.
- New `AudioRecorder.warmup()` shared by the launch-time priming and by manual recovery paths. `isWarm` tracks whether the engine has been started successfully at least once.

## [0.1.3] - 2026-05-09

Reliability release: fixes intermittent silent recordings caused by other apps quietly rerouting the system default input device (Microsoft Teams loopback, BlackHole, iPhone Continuity, etc.).

### Fixed

- **Recordings no longer come back empty when another app reroutes the system default input.** VoxPrompt now pins its capture to a specific CoreAudio device by UID (defaults to the built-in microphone) instead of riding on `AVAudioRecorder`'s implicit default-input lookup. When Teams Loopback, BlackHole, an iPhone Continuity microphone or any other input becomes the default mid-session, dictation keeps working on the chosen device.
- **No more "Sous-titrage Société Radio-Canada" artefacts being pasted on silent input.** Whisper hallucinates training-set artefacts when fed audio below the noise floor. The capture path now computes the file RMS at stop time and short-circuits transcription with an "Aucun son" HUD message when the level is under -50 dBFS, instead of pasting garbage into the focused app.

### Changed

- **`AudioRecorder` migrated from `AVAudioRecorder` to `AVAudioEngine` + `AVAudioConverter`.** The legacy `AVAudioRecorder` API has no way to select an input device on macOS, it always follows the system default. The new engine path explicitly sets `kAudioOutputUnitProperty_CurrentDevice` on the input audio unit before tapping, then resamples to 16 kHz mono PCM 16-bit on the fly via a streaming `AVAudioConverter`. The converter callback returns `.noDataNow` between buffers; `.endOfStream` would terminally close the converter and silently drop every subsequent tap callback after the first one (which would cap every recording at ~100 ms regardless of how long the hotkey is held).

### Added

- **Detailed audio capture logs** under `VOXPROMPT_DEBUG=1`: device name and input format on `rec start`, file size and computed RMS on `rec stop`, explicit `silence detected` line when transcription is short-circuited.
- **`Settings.preferredInputUID`** (`audio.preferredInputUID` UserDefaults key): string UID of the CoreAudio input device to pin. `nil` falls back to the system default. Defaults to `BuiltInMicrophoneDevice`. A future Preferences UI can expose a device picker that writes this key.

## [0.1.2] - 2026-05-06

Quality-of-life release: launch VoxPrompt automatically at login.

### Added

- **Launch at login** toggle in Preferences (new "Démarrage" section). Uses the modern `SMAppService.mainApp` API (macOS 13+), no helper bundle required. The UI reflects the live status, including the "Validation requise" hint when macOS is waiting for the user to confirm the login item in Settings > General > Login Items.
- New `LoginItem.swift` wrapper around `SMAppService` exposing `isEnabled`, `requiresApproval`, and `setEnabled(_:)`.

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
