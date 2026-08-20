import Cocoa
import SwiftUI
import AVFoundation
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hud: HUDController!
    private var hotkey: HotkeyManager!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let paster = Paster()
    private var streaming: StreamingSession?

    /// Vrai de l'appui sur la touche jusqu'a la fin du collage. Sans ce verrou, un second
    /// appui pendant une transcription fait se chevaucher deux cycles : les deux sauvegardes
    /// du presse-papier se croisent et la cible recoit l'ancien contenu au lieu du texte dicte.
    private var dictationInFlight = false

    /// Surveillance de l'accessibilite tant qu'elle manque. Les moniteurs clavier globaux
    /// n'emettent rien sans elle, et macOS ne previent pas quand l'utilisateur l'accorde :
    /// il faut donc les reinstaller nous-memes des que le trust bascule.
    private var accessibilityWatch: Timer?

    /// Instant du debut de la prise, pour ecarter les appuis trop brefs.
    private var recordingStartedAt: Date?

    // MARK: Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupPopover()
        hud = HUDController()
        hud.bindLevels(recorder.levelPublisher.eraseToAnyPublisher())
        setupRecorder()
        setupHotkey()
        setupEngineStatus()
        setupSessionObservers()

        Task { @MainActor in
            _ = await Permissions.requestMicrophone()
        }
        Task { await transcriber.warmup() }
        Task { @MainActor in
            AppState.shared.inputDevices = AudioRecorder.availableInputDevices()
            await UpdateChecker.shared.checkIfEnabled()
        }

        // Pre-arme CoreAudio hors du main thread : au demarrage de la machine, le demon HAL
        // met un instant a se stabiliser et la toute premiere prise echouerait.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.recorder.warmup()
        }

        checkAccessibilityAtLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityWatch?.invalidate()
        hotkey?.stop()
        if recorder.isRecording { _ = recorder.stop() }
    }

    // MARK: Barre de menus

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
            onModelChange: { [weak self] _ in
                guard let self else { return }
                Task { await self.transcriber.reload() }
            },
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
            AppState.shared.inputDevices = AudioRecorder.availableInputDevices()
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

    private func openPreferences() {
        guard let button = statusItem.button, !popover.isShown else { return }
        togglePopover(button)
    }

    // MARK: Branchements

    private func setupRecorder() {
        // Le peripherique epingle peut disparaitre en pleine dictee (casque debranche,
        // iPhone qui s'eloigne). L'enregistrement est deja arrete quand on arrive ici :
        // sans ce rappel, le HUD resterait fige sur "J'ecoute" jusqu'au prochain appui.
        recorder.onDeviceLost = { [weak self] in
            // Le recorder garantit l'appel sur le main thread : on l'affirme au compilateur
            // plutot que de passer par un Task, qui retarderait la sortie de l'etat "J'ecoute".
            MainActor.assumeIsolated {
                guard let self else { return }
                self.streaming = nil
                self.dictationInFlight = false
                self.hud.show(state: .error(message: "Micro déconnecté"))
                VPLog.log("input device lost during recording")
            }
        }
    }

    private func setupHotkey() {
        hotkey = HotkeyManager()
        hotkey.onPress = { [weak self] _ in
            Task { @MainActor in self?.startRecording() }
            // Rechauffe le moteur pendant que l'utilisateur parle : au relachement, le
            // decodeur est deja pret, ce qui supprime le delai a froid.
            Task { @MainActor in await self?.transcriber.keepWarm() }
        }
        hotkey.onRelease = { [weak self] target in
            Task { @MainActor in await self?.stopAndTranscribe(target: target) }
        }
        hotkey.start(binding: Settings.shared.hotkey)
    }

    /// Relaie l'etat du moteur vers le panneau de preferences et vers le HUD pendant
    /// un telechargement de modele, qui dure plusieurs minutes au premier lancement.
    private func setupEngineStatus() {
        transcriber.statusHandler = { status in
            Task { @MainActor in
                let state = AppState.shared
                switch status {
                case .idle:
                    state.engineStatus = "En veille"
                    state.engineBusy = true
                case .downloading(let progress):
                    state.engineStatus = "Téléchargement du modèle, \(Int(progress * 100)) %"
                    state.engineBusy = true
                case .loading:
                    state.engineStatus = "Chargement du modèle…"
                    state.engineBusy = true
                case .warming:
                    state.engineStatus = "Préparation du décodeur…"
                    state.engineBusy = true
                case .ready(let profile):
                    state.engineStatus = "Prêt · \(profile)"
                    state.engineBusy = false
                case .failed(let message):
                    state.engineStatus = message
                    state.engineBusy = true
                }
            }
        }
    }

    private func setupSessionObservers() {
        // Verrouillage de session ou bascule d'utilisateur : le relachement de la touche
        // ne nous parviendra jamais, et le micro resterait ouvert indefiniment.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkey?.forceRelease() }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkey?.forceRelease() }
        }
    }

    // MARK: Accessibilite

    private func checkAccessibilityAtLaunch() {
        guard Permissions.accessibility(prompt: false) != .granted else { return }

        VPLog.log("accessibility missing at launch, prompting user")
        _ = Permissions.accessibility(prompt: true)
        hud.show(state: .error(message: "Autorise l'accessibilité"))
        // Le panneau montre l'etat des trois autorisations et le bouton qui va bien.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.openPreferences()
        }
        startAccessibilityWatch()
    }

    private func startAccessibilityWatch() {
        accessibilityWatch?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
            guard let self else { t.invalidate(); return }
            guard Permissions.accessibility(prompt: false) == .granted else { return }
            t.invalidate()
            self.accessibilityWatch = nil
            // Les moniteurs installes sans trust ne recevront jamais rien, meme une fois
            // l'autorisation accordee : il faut les reinstaller.
            VPLog.log("accessibility granted, reinstalling hotkey monitors")
            self.hotkey.start(binding: Settings.shared.hotkey)
            self.hud.show(state: .done)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityWatch = timer
    }

    // MARK: Dictee

    private func startRecording() {
        guard !recorder.isRecording else { return }
        guard !dictationInFlight else {
            VPLog.log("dictation already in flight, ignoring hotkey press")
            return
        }

        // Sans autorisation micro, macOS livre un flux de zeros sans jamais lever d'erreur :
        // on le dit franchement plutot que d'afficher "Aucun son" apres coup.
        let micState = Permissions.microphone()
        guard micState == .granted else {
            VPLog.log("microphone permission is \(micState), aborting recording")
            hud.show(state: .error(message: "Micro non autorisé"))
            if micState == .notDetermined {
                Task { _ = await Permissions.requestMicrophone() }
            } else {
                Permissions.openMicrophoneSettings()
            }
            return
        }

        dictationInFlight = true
        recordingStartedAt = Date()
        hud.show(state: .recording)
        if Settings.shared.streamingEnabled {
            let session = StreamingSession(transcriber: transcriber)
            streaming = session
            recorder.sampleHandler = { session.ingest($0) }
        } else {
            streaming = nil
            recorder.sampleHandler = nil
        }
        do {
            try recorder.start()
        } catch {
            dictationInFlight = false
            recordingStartedAt = nil
            streaming = nil
            recorder.sampleHandler = nil
            let nsErr = error as NSError
            hud.show(state: .error(message: Self.recorderMessage(for: nsErr)))
            VPLog.log("Recorder error: \(error) (domain=\(nsErr.domain) code=\(nsErr.code))")
        }
    }

    /// Traduit les codes du domaine `VoxPrompt.Recorder` en message utilisable. Les echecs
    /// d'armement de l'unite audio (30 a 41) sont transitoires au demarrage de la machine :
    /// un second appui suffit. Les autres demandent une action.
    private static func recorderMessage(for error: NSError) -> String {
        guard error.domain == "VoxPrompt.Recorder" else { return "Audio non prêt, réessaye" }
        switch error.code {
        case 40: return "Aucun micro détecté"
        case 50, 51, 52: return "Écriture audio impossible"
        case 30...41, 10: return "Audio non prêt, réessaye"
        default: return "Micro KO"
        }
    }

    private func stopAndTranscribe(target: NSRunningApplication?) async {
        // NE PAS liberer le verrou ici. Si on n'enregistre pas, de deux choses l'une :
        // soit aucun cycle n'est en cours et le verrou est deja libre, soit il appartient
        // a un cycle encore en vol. C'est le cas du relachement synthetise en double par
        // le watchdog : le second passage liberait le verrou du premier, l'appui suivant
        // demarrait par-dessus, et les deux collages s'entrelacaient.
        guard recorder.isRecording else { return }
        defer { dictationInFlight = false }

        let session = streaming
        streaming = nil
        let started = recordingStartedAt
        recordingStartedAt = nil
        let url = recorder.stop()
        let rms = recorder.lastRMS

        // Appui trop bref pour porter de la parole (clic accidentel, rebond de touche) :
        // on jette sans rien transcrire. Whisper hallucine volontiers un "Merci." sur
        // quelques centiemes de seconde de bruit, qui se collerait alors dans l'app active.
        let duration = started.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if duration < 0.35 {
            VPLog.log(String(format: "press too short (%.2fs), dictation discarded", duration))
            try? FileManager.default.removeItem(at: url)
            hud.hide()
            return
        }
        VPLog.log("stop file=\(url.lastPathComponent) rms=\(rms) target=\(target?.localizedName ?? "?")")

        // Whisper hallucine des artefacts d'entrainement quand l'entree est sous le bruit
        // de fond : on saute la transcription plutot que de coller n'importe quoi.
        if rms < 0.003 {
            VPLog.log("silence detected rms=\(rms) device=\(recorder.lastDeviceName) — skip transcription")
            hud.show(state: .error(message: "Aucun son (\(recorder.lastDeviceName))"))
            try? FileManager.default.removeItem(at: url)
            return
        }

        hud.show(state: .transcribing)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            // Voie rapide : les segments deja transcrits pendant la dictee, plus la queue.
            // Si un segment a echoue en vol, finish() renvoie nil et on retombe sur le
            // decodage complet du WAV, qui est ecrit en parallele exactement pour ca.
            let text: String
            if let session, let streamed = await session.finish() {
                text = streamed
            } else {
                if session != nil { VPLog.log("streaming failed — batch fallback on wav") }
                text = try await transcriber.transcribe(fileURL: url)
            }
            VPLog.log("result: \"\(text)\"")

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                hud.show(state: .error(message: "Silence"))
                return
            }
            switch await paster.copyAndPaste(trimmed, targetApp: target) {
            case .pasted:
                hud.show(state: .done)
            case .clipboardOnly(let reason):
                // Le texte n'est pas perdu : il attend un Cmd+V. Ce n'est pas une erreur.
                hud.show(state: .clipboard(reason: reason))
            }
        } catch let e as Transcriber.TranscriberError {
            switch e {
            case .timeout:
                hud.show(state: .error(message: "Trop long, réessaye"))
            case .modelUnavailable(let message):
                hud.show(state: .error(message: message))
            }
            VPLog.log("Transcriber error: \(e)")
        } catch {
            hud.show(state: .error(message: "Transcription KO"))
            VPLog.log("Transcriber error: \(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
