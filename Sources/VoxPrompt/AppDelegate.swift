import Cocoa
import SwiftUI
import AVFoundation
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverMonitor: Any?
    private var hud: HUDController!
    private var hotkey: HotkeyManager!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let paster = Paster()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupPopover()
        hud = HUDController()
        hud.bindLevels(recorder.levelPublisher.eraseToAnyPublisher())
        setupHotkey()
        requestMicrophoneAccess()
        Task { await transcriber.warmup() }
        // Arm CoreAudio off the main thread so the first user hotkey doesn't race the
        // HAL daemon at boot (cold start would otherwise fail with "Mic KO" and require
        // a manual app relaunch). 600 ms is enough for TCC + HAL to settle on M-series
        // Macs in practice.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.recorder.warmup()
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoxPrompt")
            btn.image?.isTemplate = true
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 560)

        let view = PreferencesView(
            onHotkeyChange: { [weak self] new in self?.hotkey.start(binding: new) },
            onQuit: { [weak self] in
                self?.popover.performClose(nil)
                NSApp.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quitter VoxPrompt", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func setupHotkey() {
        hotkey = HotkeyManager()
        hotkey.onPress = { [weak self] _ in
            Task { @MainActor in self?.startRecording() }
        }
        hotkey.onRelease = { [weak self] target in
            Task { @MainActor in await self?.stopAndTranscribe(target: target) }
        }
        hotkey.start(binding: Settings.shared.hotkey)
    }

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    @MainActor private func startRecording() {
        guard !recorder.isRecording else { return }
        hud.show(state: .recording)
        do {
            try recorder.start()
        } catch {
            // Distinguish two failure modes: HAL not yet ready right after boot (transient,
            // retry should work) vs. permission/device actually missing (user-facing).
            let nsErr = error as NSError
            let isHALColdStart = nsErr.domain == NSOSStatusErrorDomain
                || nsErr.domain == "com.apple.coreaudio.avfaudio"
                || nsErr.domain == "VoxPrompt.Recorder" && nsErr.code == 10
            let message = isHALColdStart ? "Audio non prêt, réessaye" : "Mic KO"
            hud.show(state: .error(message: message))
            VPLog.log("Recorder error: \(error) (domain=\(nsErr.domain) code=\(nsErr.code))")
        }
    }

    @MainActor private func stopAndTranscribe(target: NSRunningApplication?) async {
        guard recorder.isRecording else { return }
        let url = recorder.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let rms = recorder.lastRMS
        VPLog.log("stop file=\(url.lastPathComponent) size=\(size) bytes target=\(target?.localizedName ?? "?")")

        // Whisper hallucinates training-set artefacts ("Sous-titrage Société Radio-Canada", etc.)
        // when the input is below the noise floor. Skip transcription instead of pasting garbage.
        if rms < 0.003 {
            VPLog.log("silence detected rms=\(rms) device=\(recorder.lastDeviceName) — skip transcription")
            hud.show(state: .error(message: "Aucun son (\(recorder.lastDeviceName))"))
            try? FileManager.default.removeItem(at: url)
            return
        }

        hud.show(state: .transcribing)
        do {
            let text = try await transcriber.transcribe(fileURL: url)
            VPLog.log("result: \"\(text)\"")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                hud.show(state: .done)
                await paster.copyAndPaste(trimmed, targetApp: target)
            } else {
                hud.show(state: .error(message: "Silence"))
            }
        } catch {
            hud.show(state: .error(message: "Transcription KO"))
            VPLog.log("Transcriber error: \(error)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
