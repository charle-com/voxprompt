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
        hotkey.onPress = { [weak self] in
            Task { @MainActor in self?.startRecording() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in await self?.stopAndTranscribe() }
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
            hud.show(state: .error(message: "Mic KO"))
            VPLog.log("Recorder error: \(error)")
        }
    }

    @MainActor private func stopAndTranscribe() async {
        guard recorder.isRecording else { return }
        let url = recorder.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        VPLog.log("stop file=\(url.lastPathComponent) size=\(size) bytes")
        hud.show(state: .transcribing)
        do {
            let text = try await transcriber.transcribe(fileURL: url)
            VPLog.log("result: \"\(text)\"")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                paster.copyAndPaste(trimmed)
                hud.show(state: .done)
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
