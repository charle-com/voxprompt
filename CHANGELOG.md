# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-20

Stability release. VoxPrompt now holds its macOS permissions across updates, never touches your audio output devices, and cannot leave the microphone open. This is the first version considered production ready.

### Fixed

- **Permissions silently revoked (root cause).** The app was signed with the hardened runtime but shipped no entitlements file. Verified on macOS 26.5.2 with three otherwise identical bundles: with the runtime flag and no entitlements, `AVCaptureDevice.requestAccess` returns `false` in 0.00 s and a real capture returns 57344 frames of pure zeroes (RMS 0.000000) with no error raised anywhere. The app believes it is recording and writes a silent WAV. An older TCC grant masks the problem until macOS re-evaluates it, which is why it looked like "updates break the permissions". `VoxPrompt.entitlements` now declares `com.apple.security.device.audio-input` and `com.apple.security.automation.apple-events`, and `build.sh` refuses to produce a bundle without them. The designated requirement is unchanged, so existing grants survive the update.
- **Bluetooth headphones degraded while VoxPrompt was merely running.** `AVAudioEngine` attaches the default input AND output devices as soon as `inputNode` is touched, which pushed AirPods into hands-free profile (24 kHz) even when idle. Capture is now an input-only AudioUnit HAL bound to an explicitly resolved device, so the output side is never touched: verified with the speakers staying at `running=0` throughout a recording.
- **Microphone could stay open forever.** A missed key-up (locked screen, secure input field, another app swallowing the event, popover holding focus) left the recorder running with no way back. Fixed with a local event monitor alongside the global one, a 250 ms watchdog that reads the real physical key state, a hard 180 s cap, and forced release on session lock and system sleep.
- **Crash on the second recording attempt after a cold-start failure.** A failed start left the audio tap installed; the next attempt hit an unrecoverable ObjC exception. The audio unit is now fully torn down on every error path.
- **Model could be corrupted on first launch.** Warmup did not publish its loading task, so pressing the hotkey during startup began a second concurrent `WhisperKit(config)`, and two downloads wrote the same incomplete file. All loading paths now share a single task: measured 6 concurrent calls resulting in exactly 1 model load.
- **A frozen decode permanently consumed a thread.** Abandoned inference tasks stayed on Swift's cooperative pool, and after a few hangs the whole app stopped responding. Inference now runs off the cooperative pool, the watchdog timer is cancelled on success, and a timed-out pipeline is discarded rather than reused.
- **Wrong clipboard content pasted into slow apps.** The 250 ms fixed delay before restoring the clipboard let slow targets paste the previous content. Restoration now waits for the target to consume the text, is skipped entirely if you copied something in the meantime, and never replays password-manager entries marked concealed or transient.
- **The paste fallback chain was unreachable.** `postCmdV` always reported success, so AppleScript was never attempted and the HUD claimed "pasted" when nothing had been. Success is now determined from the actual target state.
- **A phrase could vanish during streaming.** Two locks guarded the segment chain, so a natural cut and the final flush could run in parallel and one result was dropped without any error. The chain is now a single critical section and every task is awaited.
- **Legitimate speech mangled by the anti-repetition guard.** "06 44 44 44 44" collapsed to "06 44" and "non non non" to "non". Numeric tokens are exempt, thresholds are raised, and the mid-decode abort only fires when the text stops progressing.
- **Glossary rewrote real words.** "gel" became "GYL", "dandy" became "Gandy". Fuzzy matching now scales with term length and never touches a word the system dictionary recognises.
- **HUD appeared on the wrong display** on multi-monitor setups, and reported a paste that had not happened.

### Added

- **Permission dashboard** in Preferences: live state of Microphone, Accessibility, and Automation, direct links to the right settings pane, and a repair action for a desynchronised TCC entry.
- **Accessibility prompt at launch** when the permission is missing, with automatic reinstallation of the hotkey monitors the moment it is granted. Previously the app just sat there, silent.
- **Warning banner** when the app runs from quarantine or outside /Applications, the two situations where macOS silently drops its permissions.
- **Microphone picker** in Preferences, so a Bluetooth headset or a virtual device connecting mid-session cannot hijack the input.
- **Engine status** surfaced in Preferences and in the HUD, including model download progress.
- **Optional update check**, off by default. One request per day to the GitHub releases API, which only ever opens the release page. Nothing is downloaded or installed automatically.
- **`install.sh`**, a one-line installer that verifies the bundle signature against the project certificate before copying, and avoids the Gatekeeper prompt entirely.
- **Single-instance guard**: a second copy of the app now steps aside instead of double-pasting every dictation.
- **22 unit tests** covering the text cleanup logic, in a `VoxPromptCore` library so they can actually run under `swift test`.

### Changed

- `build.sh` verifies the signature, the entitlements and the designated requirement before finishing, and no longer falls back to ad-hoc signing, which was itself a cause of lost permissions. `--install` quits the running instance before replacing it, since replacing a running bundle invalidates its signature at runtime.
- `package-dmg.sh` refuses to build a DMG from an unverified bundle and ships an installation note.
- Forced streaming cuts now land on the quietest point of the last second instead of mid-word.
- Compute profile cache is keyed by macOS build AND model, expires after 14 days, and requires two consecutive timeouts before persisting a downgrade.

### Known limitation

- Glossary terms cannot be injected as decoder prompt tokens. Measured on WhisperKit 0.18: beyond two forced prompt tokens the decoder immediately predicts end-of-transcript and returns an empty segment, regardless of content or decoding options. Glossary correction therefore runs after transcription, and prompt injection stays disabled with the measurement documented in the code.

## [0.2.0] - 2026-08-02

Feature release: **streaming transcription**. Until now the entire clip was transcribed after key release (batch). The audio stream is now segmented on natural pauses (250 ms of silence, segments between 2.5 s and 12 s) and each segment is transcribed in the background **while the user is still speaking**. On key release only the last segment remains to transcribe, so perceived latency drops from "duration-of-dictation-dependent" to roughly the duration of the last sentence.

### Added

- **`StreamingSession`**: accumulates the 16 kHz mono float samples emitted by the recorder, cuts segments on silence (RMS < 0.004 for 250 ms, min segment 2.5 s, forced cut at 12 s), and chains background transcriptions in order. Per-segment anti-hallucination guard (RMS < 0.003 means the segment is skipped), final `collapseRepetitions` pass over the joined text.
- **`AudioRecorder.sampleHandler`**: the tap callback now also hands the converted 16 kHz buffers to the streaming session, in parallel with the WAV file which is still written as a safety net.
- **Preferences toggle** "Dictée en continu" (default: on) to fall back to the historical batch behavior.

### Safety

- If any in-flight segment fails (decoder timeout, pipeline error), `finish()` returns nil and the app transparently falls back to batch transcription of the full WAV; worst case is exactly the previous behavior.

## [0.1.5] - 2026-06-03

Reliability release: after upgrading to macOS 26.5.1, dictation would hang forever ("transcription à l'infini"), the HUD stayed in "transcribing" and never returned. Root-caused by isolating the WhisperKit compute backends on the machine: with the Turbo model on macOS 26.5.1, CoreML inference **deadlocks on both the Apple Neural Engine and the GPU/Metal** (decoder frozen, 30s+ with zero tokens emitted), and only the **CPU** backend decodes correctly. The 0.1.4 anti-loop `DecodingOptions` recipe couldn't help because the decoder never even reached the token-generation stage. This release moves inference to CPU and adds independent safety nets.

### Fixed

- **Dictation hanging forever on macOS 26.5.1 (root cause).** WhisperKit defaults the audio encoder and text decoder to `.cpuAndNeuralEngine`; both the ANE and the GPU (`.cpuAndGPU`) deadlock natively on this OS for the Turbo model. The pipeline now pins every stage (`melCompute`, `audioEncoderCompute`, `textDecoderCompute`, `prefillCompute`) to `.cpuOnly`, the only backend verified to decode. Measured steady-state latency on CPU is ~2s for a short dictation, perfectly usable.
- **First-dictation lag.** CPU inference pays a one-time CoreML graph-compilation cost (~8s) on the first decode. The launch warmup now decodes 2s of low-amplitude white noise (`sampleLength: 4`, VAD off) to force that compilation up front, so the user's first real dictation is already fast (~2s) instead of stalling.

### Added: defense in depth (independent of the OS bug)

- **Watchdog timeout.** Transcription runs under `runWithTimeout` (a `withCheckedThrowingContinuation` racing the decode against `max(20s, audioSeconds × 5)`). If a decode ever freezes again, the continuation is resolved by the timeout, the frozen task is abandoned, and the HUD recovers with "Trop long, réessaye" instead of spinning forever. Unlike a `TaskGroup`, this does not re-block waiting on the frozen child.
- **In-callback loop detection** (`isRepetitionLoop`) and **final-text repetition collapse** (`collapseRepetitions`) for the distinct token-repetition failure mode: a 1-to-6-word pattern repeating is cut at the source mid-decode and/or collapsed in the final text, while a deliberate doubling ("très très bien") is preserved.

### Changed

- **HUD error disambiguation.** A transcription that hits the watchdog shows "Trop long, réessaye" (transient, just retry) instead of the generic "Transcription KO".

## [0.1.4] - 2026-05-19

Reliability release: fixes two issues surfaced after upgrading to macOS 26.5. First, the very first dictation right after a Mac boot would frequently fail with a generic "Mic KO" HUD until the app was relaunched. Second, the Whisper decoder could enter an infinite token-repetition loop on the Turbo model, leaving the HUD spinning forever.

### Fixed

- **Cold-start "Mic KO" right after boot.** At boot, the CoreAudio HAL daemon and TCC subsystem take a moment to settle. The first `AVAudioEngine.start()` after launch-at-login would race that warmup window and fail with an opaque `OSStatus`, leaving the engine in a broken state until the app was relaunched manually. VoxPrompt now arms the input audio unit off the main thread ~600 ms after launch (one start/stop cycle through `engine.prepare()` + `engine.start()` + `engine.stop()`), so the first user hotkey runs against an already-warm unit. If the start still throws, the engine is rebuilt and the call is retried once after a 250 ms delay.
- **Whisper decoder loops on Turbo (macOS 26.x).** At `temperature: 0.0` with `withoutTimestamps: false`, the greedy decoder has no escape hatch when it falls into a token-repetition cycle, the HUD then stays in "transcribing" forever. The `DecodingOptions` now follow the standard Whisper anti-loop recipe: `withoutTimestamps: true`, explicit `temperatureFallbackCount: 3`, `compressionRatioThreshold: 2.4`, `logProbThreshold: -1.0`, `noSpeechThreshold: 0.6`. The decoder now retries the segment at a higher temperature whenever the output compresses too well (signature of repeated tokens) or the average log-probability collapses.

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

## [0.1.0] - 2026-04-18

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
