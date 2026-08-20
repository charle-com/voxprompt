import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

/// Capture micro basée sur une unité CoreAudio `kAudioUnitSubType_HALOutput` en ENTRÉE SEULE.
///
/// Pourquoi pas `AVAudioEngine` : sur macOS, dès que l'engine touche `inputNode`, il accroche
/// les périphériques d'entrée ET de sortie par défaut du système. Avec des AirPods Max en
/// sortie, le casque bascule en profil mains-libres (24 kHz au lieu de 48, son dégradé) dès le
/// lancement de l'app, sans même enregistrer, et cela malgré l'épinglage du micro interne.
/// Ici l'AUHAL n'a que son bus d'entrée activé, le device d'entrée est fixé explicitement
/// AVANT l'initialisation, et le device de sortie n'est jamais touché, nulle part.
///
/// Pipeline : callback d'entrée HAL -> `AudioUnitRender` dans un buffer préalloué -> file
/// série d'écriture -> `AVAudioConverter` vers 16 kHz mono -> WAV PCM 16 bits + `sampleHandler`
/// + RMS cumulé + niveau publié.
///
/// Thread-safety : tout l'état vit derrière `stateQueue` (série). Le thread IO temps réel ne
/// lit que `renderSession`, sous `os_unfair_lock`, et n'alloue rien (pool de buffers).
/// Thread-safe par construction : tout l'etat passe par la queue serie interne et
/// `stop()` pose une barriere avant de rendre la main. Le marquage est donc sur.
final class AudioRecorder: @unchecked Sendable {

    struct InputDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    // MARK: API publique

    /// Reçoit chaque buffer converti (16 kHz mono Float32) pendant l'enregistrement, depuis la
    /// file d'écriture audio (jamais le main thread). Snapshoté au `start()` : le modifier
    /// pendant une prise n'affecte pas la prise en cours. Remis à nil par `stop()`.
    var sampleHandler: (([Float]) -> Void)? {
        get { sync { _sampleHandler } }
        set { sync { _sampleHandler = newValue } }
    }

    /// Niveau 0...1 (courbe dB sur 50 dB de dynamique), envoyé sur le main thread, lissé à
    /// ~30 émissions par seconde (un callback HAL toutes les 10 ms saturerait le HUD).
    let levelPublisher = PassthroughSubject<Float, Never>()

    /// Appelé sur le main thread si le device épinglé disparaît PENDANT un enregistrement.
    /// La prise est alors arrêtée, son WAV supprimé, et `isRecording` repasse à false.
    var onDeviceLost: (() -> Void)? {
        get { sync { _onDeviceLost } }
        set { sync { _onDeviceLost = newValue } }
    }

    var isRecording: Bool { sync { session != nil } }
    var lastDeviceName: String { sync { _lastDeviceName } }
    /// RMS de la dernière prise, cumulé en streaming sur les échantillons 16 kHz pendant la
    /// capture (le fichier n'est jamais relu pour ça).
    var lastRMS: Float { sync { _lastRMS } }

    init() {
        queueKey = DispatchSpecificKey<Void>()
        stateQueue.setSpecific(key: queueKey, value: ())
        installHardwareListeners()
    }

    deinit {
        removeHardwareListeners()
        // Le deinit ne passe pas par la queue : plus personne ne détient l'objet.
        let pending = session
        session = nil
        renderLock.withLock { renderSession = nil }
        // Disposer l'unité AVANT de toucher à la prise : après ça, plus aucun callback HAL
        // ne peut atteindre `self`, dont la mémoire est en train de partir.
        disposeUnitUnsafe()
        if let pending {
            pending.writeQueue.sync {
                pending.closed = true
                pending.file = nil
            }
            try? FileManager.default.removeItem(at: pending.url)
        }
    }

    /// Prépare l'unité pour le device préféré. Idempotent, ne démarre rien. À appeler hors du
    /// main thread au lancement : la première initialisation HAL après un boot coûte quelques
    /// dizaines de ms, et une unité déjà initialisée rend `start()` quasi instantané.
    func warmup() {
        sync {
            guard session == nil else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                let reused = try prepareUnit(for: Settings.shared.preferredInputUID)
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                VPLog.log("audio warmup OK device=\(_lastDeviceName) format=\(formatDescription) reused=\(reused) in \(ms)ms")
            } catch {
                VPLog.log("audio warmup failed: \(error.localizedDescription), first start() will retry")
                disposeUnitUnsafe()
            }
        }
    }

    /// Ouvre le WAV temporaire et démarre la capture. Lève une `NSError` de domaine
    /// `VoxPrompt.Recorder` explicite ; après un échec l'état est propre (unité disposée,
    /// WAV supprimé), l'appui suivant repart de zéro.
    func start() throws {
        try sync {
            guard session == nil else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try startUnsafe()
            } catch {
                // Une seule relance : une erreur HAL transitoire (daemon pas encore posé après
                // un boot, device en cours de réénumération) se résout en recréant l'unité.
                VPLog.log("rec start failed once: \(error.localizedDescription), rebuilding unit and retrying")
                disposeUnitUnsafe()
                try startUnsafe()
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            VPLog.log("rec start device=\(_lastDeviceName) format=\(formatDescription) in \(ms)ms")
        }
    }

    /// Arrête la capture, attend la fin du dernier callback, finalise le WAV et renvoie son URL.
    /// Hors enregistrement, renvoie le dossier temporaire (comportement historique).
    @discardableResult
    func stop() -> URL {
        sync {
            guard let s = session else { return FileManager.default.temporaryDirectory }
            let frames = finishCaptureUnsafe(s)
            _sampleHandler = nil
            VPLog.log(String(format: "rec stop file=%@ rms=%.4f frames=%lld device=%@",
                             s.url.lastPathComponent, _lastRMS, frames, _lastDeviceName))
            return s.url
        }
    }

    // MARK: État interne (accès uniquement sur `stateQueue`)

    private let stateQueue = DispatchQueue(label: "fr.charlesneveu.voxprompt.recorder")
    private let queueKey: DispatchSpecificKey<Void>

    private var _sampleHandler: (([Float]) -> Void)?
    private var _onDeviceLost: (() -> Void)?
    private var _lastDeviceName: String = "unknown"
    private var _lastRMS: Float = 0

    /// Unité AUHAL initialisée (ou nil). Toujours stoppée hors enregistrement.
    private var unit: AudioUnit?
    private var unitDeviceID: AudioDeviceID = 0
    private var unitDeviceUID: String = ""
    /// true si le device de l'unité a été résolu depuis le défaut système (et non épinglé).
    private var unitFollowsDefault = false
    private var unitFormat: AVAudioFormat?
    private var unitMaxFrames: AVAudioFrameCount = 4096

    /// Prise en cours. Non-nil <=> isRecording.
    private var session: CaptureSession?

    /// Contexte lu par le callback HAL (thread IO), protégé par un verrou léger.
    private let renderLock = UnfairLock()
    private var renderSession: CaptureSession?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Nombre de buffers en vol au maximum entre le thread IO et la file d'écriture.
    /// 16 buffers de 4096 frames mono = 256 Ko, soit ~1,3 s de marge à 48 kHz.
    private static let poolSize = 16

    private var formatDescription: String {
        guard let f = unitFormat else { return "none" }
        return "\(Int(f.sampleRate))Hz/\(f.channelCount)ch"
    }

    /// Exécute `work` sur la queue d'état, sans interblocage si on y est déjà (listeners).
    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try stateQueue.sync(execute: work)
    }

    // MARK: Démarrage / arrêt (sur stateQueue)

    private func startUnsafe() throws {
        _ = try prepareUnit(for: Settings.shared.preferredInputUID)
        guard let u = unit, let inFormat = unitFormat else {
            throw Self.error(37, "Unité audio non initialisée")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxprompt-\(UUID().uuidString).wav")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let outFile = try AVAudioFile(forWriting: url, settings: fileSettings)
            let outFormat = outFile.processingFormat
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw Self.error(51, "Converter audio impossible (\(inFormat) -> \(outFormat))")
            }
            guard let pool = BufferPool(format: inFormat, frameCapacity: unitMaxFrames,
                                        count: Self.poolSize) else {
                throw Self.error(52, "Allocation des buffers de capture impossible")
            }

            let s = CaptureSession(url: url, file: outFile, outFormat: outFormat,
                                   converter: converter, inFormat: inFormat, unit: u,
                                   pool: pool, handler: _sampleHandler)
            s.onLevel = { [weak self] linear in
                DispatchQueue.main.async { self?.levelPublisher.send(linear) }
            }

            renderLock.withLock { renderSession = s }
            let status = AudioOutputUnitStart(u)
            guard status == noErr else {
                renderLock.withLock { renderSession = nil }
                s.file = nil
                disposeUnitUnsafe()
                throw Self.error(38, "AudioOutputUnitStart a échoué", status: status)
            }
            session = s
        } catch let err as NSError where err.domain == Self.errorDomain {
            try? FileManager.default.removeItem(at: url)
            throw err
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Self.error(50, "Ouverture du WAV impossible : \(error.localizedDescription)")
        }
    }

    /// Stoppe l'unité, pose la barrière d'écriture, ferme le WAV et fige le RMS. Laisse `unit`
    /// initialisée pour la prise suivante. Renvoie le nombre de frames 16 kHz écrites.
    @discardableResult
    private func finishCaptureUnsafe(_ s: CaptureSession) -> Int64 {
        if let u = unit {
            // Synchrone : au retour, le HAL n'appelle plus notre callback.
            let status = AudioOutputUnitStop(u)
            if status != noErr { VPLog.log("warn: AudioOutputUnitStop status=\(status)") }
        }
        renderLock.withLock { renderSession = nil }

        // Barrière : tout callback déjà enfilé est traité, tout callback ultérieur voit
        // `closed`. Relâcher `file` ICI est ce qui finalise l'en-tête du WAV (AVAudioFile n'a
        // pas de close() : la taille du chunk data n'est écrite qu'à la libération de l'objet).
        var rms: Float = 0
        var frames: Int64 = 0
        var renderErrors = 0
        var lastRenderStatus: OSStatus = noErr
        var starved = 0
        s.writeQueue.sync {
            s.closed = true
            s.file = nil
            rms = s.rms
            frames = s.framesWritten
            renderErrors = s.renderErrors
            lastRenderStatus = s.lastRenderStatus
            starved = s.starvedBuffers
        }
        _lastRMS = rms
        session = nil
        if renderErrors > 0 {
            VPLog.log("warn: \(renderErrors) erreur(s) AudioUnitRender pendant la prise (dernier status=\(lastRenderStatus))")
        }
        if starved > 0 {
            VPLog.log("warn: \(starved) buffer(s) perdus, écriture en retard sur la capture")
        }
        return frames
    }

    /// Device épinglé disparu pendant une prise : arrêt propre, WAV supprimé, unité disposée.
    private func handleDeviceLostUnsafe() {
        guard let s = session else { return }
        VPLog.log("device lost during recording: \(_lastDeviceName) (uid=\(unitDeviceUID)), aborting take")
        finishCaptureUnsafe(s)
        _sampleHandler = nil
        try? FileManager.default.removeItem(at: s.url)
        disposeUnitUnsafe()
        if let cb = _onDeviceLost {
            DispatchQueue.main.async { cb() }
        }
    }

    // MARK: Cycle de vie de l'unité AUHAL (sur stateQueue)

    /// Garantit une unité initialisée sur le device demandé. Réutilise l'unité existante si
    /// elle pointe déjà sur le même device physique, sinon la dispose et la recrée.
    /// Renvoie true si l'unité a été réutilisée.
    @discardableResult
    private func prepareUnit(for preferredUID: String?) throws -> Bool {
        let (deviceID, followsDefault) = try Self.resolveDevice(preferredUID: preferredUID)
        let uid = Self.stringProperty(device: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let name = Self.stringProperty(device: deviceID, selector: kAudioObjectPropertyName) ?? "device"

        if unit != nil, unitDeviceID == deviceID, unitDeviceUID == uid, Self.isAlive(deviceID) {
            unitFollowsDefault = followsDefault
            _lastDeviceName = name
            return true
        }
        disposeUnitUnsafe()
        try createUnit(device: deviceID)
        unitDeviceID = deviceID
        unitDeviceUID = uid
        unitFollowsDefault = followsDefault
        _lastDeviceName = name
        return false
    }

    private func createUnit(device: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw Self.error(30, "Composant AUHAL introuvable")
        }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &newUnit)
        guard status == noErr, let u = newUnit else {
            throw Self.error(31, "AudioComponentInstanceNew a échoué", status: status)
        }

        // À partir d'ici, toute erreur dispose l'unité partiellement configurée : c'est ce qui
        // garantit qu'un premier `start()` raté ne laisse pas d'unité zombie derrière lui.
        var initialized = false
        do {
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            var one: UInt32 = 1
            var zero: UInt32 = 0
            // Entrée activée sur le bus 1, sortie DÉSACTIVÉE sur le bus 0 : l'unité ne touchera
            // jamais le device de sortie. L'ordre EnableIO puis CurrentDevice est imposé par l'AUHAL.
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                          kAudioUnitScope_Input, 1, &one, u32)
            guard status == noErr else { throw Self.error(32, "EnableIO entrée (bus 1) a échoué", status: status) }
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                          kAudioUnitScope_Output, 0, &zero, u32)
            guard status == noErr else { throw Self.error(32, "EnableIO sortie (bus 0) a échoué", status: status) }

            // CurrentDevice AVANT AudioUnitInitialize : posé après, l'unité aurait déjà accroché
            // le device d'entrée par défaut.
            var dev = device
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw Self.error(33, "CurrentDevice a échoué", status: status) }

            // Format du device côté entrée (bus 1, scope input) : on en garde le sample rate,
            // l'AUHAL convertit le type d'échantillon mais ne resample pas.
            var deviceASBD = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input, 1, &deviceASBD, &size)
            guard status == noErr else { throw Self.error(34, "Lecture du format device a échoué", status: status) }
            guard deviceASBD.mSampleRate > 0, deviceASBD.mChannelsPerFrame > 0 else {
                throw Self.error(10, "Format d'entrée invalide (\(deviceASBD.mSampleRate)Hz/\(deviceASBD.mChannelsPerFrame)ch)")
            }

            let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var clientASBD = Self.floatASBD(sampleRate: deviceASBD.mSampleRate, channels: 1)
            status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Output, 1, &clientASBD, asbdSize)
            if status != noErr, deviceASBD.mChannelsPerFrame > 1 {
                // Quelques devices refusent le downmix mono côté AUHAL : on prend leur nombre de
                // canaux natif, c'est l'AVAudioConverter qui ramènera le flux en mono.
                VPLog.log("warn: format mono refusé (status=\(status)), repli sur \(deviceASBD.mChannelsPerFrame) canaux")
                clientASBD = Self.floatASBD(sampleRate: deviceASBD.mSampleRate,
                                            channels: deviceASBD.mChannelsPerFrame)
                status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                              kAudioUnitScope_Output, 1, &clientASBD, asbdSize)
            }
            guard status == noErr else { throw Self.error(35, "Format client (bus 1) refusé", status: status) }

            // Marge sur la taille de tranche : un device avec un gros buffer IO dépasserait la
            // valeur par défaut et ferait échouer AudioUnitRender.
            let deviceFrames = Self.uint32Property(device: device, selector: kAudioDevicePropertyBufferFrameSize) ?? 0
            var maxFrames = max(UInt32(4096), deviceFrames)
            status = AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice,
                                          kAudioUnitScope_Global, 0, &maxFrames, u32)
            guard status == noErr else { throw Self.error(36, "MaximumFramesPerSlice refusé", status: status) }

            var cb = AURenderCallbackStruct(
                inputProc: audioRecorderInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback,
                                          kAudioUnitScope_Global, 0, &cb,
                                          UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw Self.error(39, "SetInputCallback a échoué", status: status) }

            status = AudioUnitInitialize(u)
            guard status == noErr else { throw Self.error(37, "AudioUnitInitialize a échoué", status: status) }
            initialized = true

            guard let fmt = AVAudioFormat(streamDescription: &clientASBD) else {
                throw Self.error(35, "AVAudioFormat invalide (\(Int(clientASBD.mSampleRate))Hz/\(clientASBD.mChannelsPerFrame)ch)")
            }
            unit = u
            unitFormat = fmt
            unitMaxFrames = AVAudioFrameCount(maxFrames)
        } catch {
            if initialized { AudioUnitUninitialize(u) }
            AudioComponentInstanceDispose(u)
            throw error
        }
    }

    /// Stoppe, désinitialise et dispose l'unité. Sans effet si aucune unité.
    private func disposeUnitUnsafe() {
        guard let u = unit else { return }
        unit = nil
        unitFormat = nil
        unitDeviceID = 0
        unitDeviceUID = ""
        unitFollowsDefault = false
        unitMaxFrames = 4096
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
    }

    // MARK: Callback HAL (thread IO temps réel)

    /// Rend les frames disponibles dans un buffer préalloué et les passe à la file d'écriture.
    /// Aucune allocation audio ici : ni conversion, ni fichier, ni `try`.
    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) -> OSStatus {
        guard frames > 0, let s = renderLock.withLock({ renderSession }) else { return noErr }
        guard let buf = s.pool.acquire() else {
            s.writeQueue.async { s.noteStarved() }
            return noErr
        }
        // Dépasser frameCapacity ferait lever une exception ObjC non rattrapable par le setter
        // de frameLength : on jette la tranche à la place.
        guard frames <= buf.frameCapacity else {
            s.pool.release(buf)
            s.writeQueue.async { s.noteRenderError(kAudio_ParamError) }
            return noErr
        }
        buf.frameLength = frames
        let status = AudioUnitRender(s.unit, flags, timestamp, bus, frames, buf.mutableAudioBufferList)
        guard status == noErr else {
            s.pool.release(buf)
            s.writeQueue.async { s.noteRenderError(status) }
            return noErr
        }
        s.writeQueue.async {
            s.process(buf)
            s.pool.release(buf)
        }
        // Toujours noErr : renvoyer une erreur ferait démonter la chaîne par le HAL.
        return noErr
    }

    // MARK: Listeners hardware (blocs exécutés sur stateQueue)

    private func installHardwareListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
        ]
        for selector in selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            // Le bloc est typé `AudioObjectPropertyListenerBlock` : sa forme ObjC est créée une
            // seule fois ici, ce qui permet à AudioObjectRemovePropertyListenerBlock de le
            // retrouver en deinit (sinon le listener survit à l'objet et le HAL crashe).
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.hardwareChangedUnsafe(selector: selector)
            }
            let status = AudioObjectAddPropertyListenerBlock(system, &addr, stateQueue, block)
            if status == noErr {
                listeners.append((addr, block))
            } else {
                VPLog.log("warn: listener \(selector) non installé (status=\(status))")
            }
        }
    }

    private func removeHardwareListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(system, &addr, stateQueue, block)
        }
        listeners.removeAll()
    }

    private func hardwareChangedUnsafe(selector: AudioObjectPropertySelector) {
        guard unit != nil else { return }
        let stillThere = Self.deviceExists(unitDeviceID, uid: unitDeviceUID) && Self.isAlive(unitDeviceID)
        if session != nil {
            // En cours de prise : on ne bascule jamais de device en vol. Seule la disparition
            // du device épinglé interrompt la prise.
            if !stillThere { handleDeviceLostUnsafe() }
            return
        }
        if !stillThere {
            VPLog.log("device \(_lastDeviceName) disparu en idle, unité invalidée")
            disposeUnitUnsafe()
        } else if selector == kAudioHardwarePropertyDefaultInputDevice, unitFollowsDefault {
            // L'unité suivait le défaut système et celui-ci vient de changer : on la recrée à
            // la prochaine prise sur le nouveau défaut.
            VPLog.log("défaut système d'entrée changé en idle, unité invalidée")
            disposeUnitUnsafe()
        }
    }

    // MARK: Résolution des devices (statique, thread-safe)

    /// Résout le device à utiliser : l'UID préféré s'il existe, sinon le défaut système (loggé).
    /// Renvoie l'ID et un drapeau indiquant si on suit le défaut.
    private static func resolveDevice(preferredUID: String?) throws -> (AudioDeviceID, Bool) {
        if let uid = preferredUID, !uid.isEmpty {
            let id = deviceID(forUID: uid)
            if id != kAudioObjectUnknown, isAlive(id), inputChannelCount(id) > 0 {
                return (id, false)
            }
            VPLog.log("warn: device préféré uid=\(uid) absent ou sans entrée, repli sur le défaut système")
        }
        let def = defaultInputDeviceID()
        guard def != kAudioObjectUnknown else {
            throw error(40, "Aucun périphérique d'entrée disponible")
        }
        return (def, true)
    }

    static func availableInputDevices() -> [InputDevice] {
        guard let ids = try? listDeviceIDs() else { return [] }
        var seen = Set<String>()
        var out: [InputDevice] = []
        for id in ids {
            guard inputChannelCount(id) > 0 else { continue }
            // Seuls les devices que le HAL marque explicitement comme cachés sont écartés :
            // un agrégat ou un device virtuel choisi sciemment par l'utilisateur reste listé.
            if uint32Property(device: id, selector: kAudioDevicePropertyIsHidden) == 1 { continue }
            guard let uid = stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID),
                  !uid.isEmpty, seen.insert(uid).inserted else { continue }
            let name = stringProperty(device: id, selector: kAudioObjectPropertyName) ?? uid
            out.append(InputDevice(uid: uid, name: name))
        }
        return out
    }

    static func defaultInputDevice() -> InputDevice? {
        let id = defaultInputDeviceID()
        guard id != kAudioObjectUnknown,
              let uid = stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(device: id, selector: kAudioObjectPropertyName) ?? uid
        return InputDevice(uid: uid, name: name)
    }

    /// RMS d'un fichier audio complet. Conservé pour les appelants externes ; `lastRMS`
    /// est désormais cumulé pendant la capture et n'en dépend plus.
    static func fileRMS(at url: URL) -> Float {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else { return 0 }
        let format = f.processingFormat
        let chunkFrames: AVAudioFrameCount = 8192
        var sumSq: Double = 0
        var sampleCount: Int = 0
        var remaining = f.length
        while remaining > 0 {
            let need = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: need) else { break }
            do { try f.read(into: buf, frameCount: need) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            if let chans = buf.floatChannelData {
                let chCount = Int(format.channelCount)
                for c in 0..<chCount {
                    let p = chans[c]
                    for i in 0..<n {
                        let s = Double(p[i])
                        sumSq += s * s
                    }
                }
                sampleCount += n * chCount
            }
            remaining -= Int64(n)
        }
        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumSq / Double(sampleCount)))
    }

    // MARK: Helpers CoreAudio

    fileprivate static let errorDomain = "VoxPrompt.Recorder"

    private static func error(_ code: Int, _ message: String, status: OSStatus? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: status.map { "\(message) (OSStatus \($0))" } ?? message]
        if let status { info["OSStatus"] = Int(status) }
        return NSError(domain: errorDomain, code: code, userInfo: info)
    }

    private static func floatASBD(sampleRate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector,
                                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    /// Traduction UID -> AudioDeviceID par le HAL (kAudioObjectUnknown si absent).
    private static func deviceID(forUID uid: String) -> AudioDeviceID {
        var cfUID: CFString = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = globalAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), ptr, &size, &deviceID)
        }
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    private static func listDeviceIDs() throws -> [AudioDeviceID] {
        var addr = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { throw error(41, "Liste des devices illisible", status: status) }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw error(41, "Liste des devices illisible", status: status) }
        return ids
    }

    private static func deviceExists(_ id: AudioDeviceID, uid: String) -> Bool {
        guard id != kAudioObjectUnknown, let ids = try? listDeviceIDs(), ids.contains(id) else { return false }
        // Un AudioDeviceID peut être recyclé après un débranchement : on recoupe par l'UID.
        return stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID) == uid
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        // Propriété absente sur certains devices : on considère alors le device vivant.
        return (uint32Property(device: id, selector: kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = globalAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, abl) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uint32Property(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = globalAddress(selector)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func stringProperty(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = globalAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}

// MARK: - Session de capture

/// État d'une prise : fichier, converter, accumulateurs. Tout le traitement (conversion,
/// écriture, handler, RMS, niveau) tourne sur `writeQueue`, en série : un `AVAudioFile` n'est
/// pas thread-safe et ne doit être touché que là. La barrière `writeQueue.sync` de stop()
/// garantit qu'aucun callback n'écrit encore quand stop() rend la main.
private final class CaptureSession {
    let url: URL
    let outFormat: AVAudioFormat
    let converter: AVAudioConverter
    let inFormat: AVAudioFormat
    let unit: AudioUnit
    let pool: BufferPool
    let handler: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?
    let writeQueue = DispatchQueue(label: "fr.charlesneveu.voxprompt.recorder.writer", qos: .userInitiated)

    // Tout ce qui suit n'est touché que sur writeQueue (y compris depuis la barrière de stop).
    /// Relâcher cette référence est ce qui ferme le WAV et écrit la taille réelle du chunk data.
    var file: AVAudioFile?
    var closed = false
    private(set) var framesWritten: Int64 = 0
    private(set) var renderErrors: Int = 0
    private(set) var lastRenderStatus: OSStatus = noErr
    private(set) var starvedBuffers: Int = 0
    private var sumSq: Double = 0
    private var sampleCount: Int = 0
    private var writeErrorLogged = false
    private var convertErrorLogged = false

    // Lissage du niveau publié : une émission toutes les 33 ms environ.
    private static let levelInterval: CFAbsoluteTime = 0.033
    private var levelSumSq: Double = 0
    private var levelCount: Int = 0
    private var lastLevelEmit: CFAbsoluteTime = 0

    init(url: URL, file: AVAudioFile, outFormat: AVAudioFormat, converter: AVAudioConverter,
         inFormat: AVAudioFormat, unit: AudioUnit, pool: BufferPool,
         handler: (([Float]) -> Void)?) {
        self.url = url
        self.file = file
        self.outFormat = outFormat
        self.converter = converter
        self.inFormat = inFormat
        self.unit = unit
        self.pool = pool
        self.handler = handler
    }

    var rms: Float {
        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumSq / Double(sampleCount)))
    }

    func noteRenderError(_ status: OSStatus) {
        renderErrors += 1
        lastRenderStatus = status
    }

    func noteStarved() {
        starvedBuffers += 1
    }

    /// Convertit un buffer au format natif en 16 kHz mono, l'écrit, le publie.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard !closed, let file, buffer.frameLength > 0 else { return }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return }

        var convertError: NSError?
        var supplied = false
        // .noDataNow et non .endOfStream : endOfStream met le converter dans un état terminal
        // et jette silencieusement tous les buffers suivants (le WAV plafonne à un buffer).
        let status = converter.convert(to: outBuf, error: &convertError) { _, ioStatus in
            if supplied { ioStatus.pointee = .noDataNow; return nil }
            supplied = true
            ioStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            if !convertErrorLogged {
                convertErrorLogged = true
                VPLog.log("convert error: \(convertError?.localizedDescription ?? "inconnue")")
            }
            return
        }
        guard outBuf.frameLength > 0 else { return }

        do {
            try file.write(from: outBuf)
            framesWritten += Int64(outBuf.frameLength)
        } catch {
            if !writeErrorLogged {
                writeErrorLogged = true
                VPLog.log("write error: \(error)")
            }
            return
        }

        guard let ch = outBuf.floatChannelData?[0] else { return }
        let n = Int(outBuf.frameLength)
        handler?(Array(UnsafeBufferPointer(start: ch, count: n)))

        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        sumSq += Double(sum)
        sampleCount += n

        levelSumSq += Double(sum)
        levelCount += n
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmit >= Self.levelInterval, levelCount > 0 else { return }
        lastLevelEmit = now
        let windowRMS = Float((levelSumSq / Double(levelCount)).squareRoot())
        levelSumSq = 0
        levelCount = 0
        let db = 20 * log10(max(windowRMS, 1e-6))
        onLevel?(max(0, min(1, (db + 50) / 50)))
    }
}

// MARK: - Pool de buffers

/// Buffers de capture préalloués : le thread IO n'alloue jamais, et le nombre de tranches en
/// vol vers la file d'écriture est borné (si l'écriture décroche, on perd des frames au lieu
/// de laisser la mémoire enfler sans limite).
private final class BufferPool {
    private let lock = UnfairLock()
    private var free: [AVAudioPCMBuffer]

    init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, count: Int) {
        guard frameCapacity > 0, count > 0 else { return nil }
        var buffers: [AVAudioPCMBuffer] = []
        buffers.reserveCapacity(count)
        for _ in 0..<count {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
            buffers.append(b)
        }
        // La capacité réservée n'est jamais dépassée : `append` ne réalloue donc jamais, y
        // compris depuis le thread IO.
        free = buffers
    }

    func acquire() -> AVAudioPCMBuffer? {
        lock.withLock { free.popLast() }
    }

    func release(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { free.append(buffer) }
    }
}

// MARK: - Callback C

/// Point d'entrée HAL : un pointeur de fonction C sans capture, qui retrouve le recorder via
/// le refCon. Aucune rétention : le recorder dispose l'unité dans son deinit avant de mourir,
/// et `AudioOutputUnitStop` est synchrone, donc plus aucun callback ne peut être en vol.
private let audioRecorderInputCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    let recorder = Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue()
    return recorder.render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
}

// MARK: - Verrou léger

/// `os_unfair_lock` avec stockage stable, utilisable depuis le thread IO (héritage de priorité,
/// contrairement à NSLock).
private final class UnfairLock {
    private let storage: UnsafeMutablePointer<os_unfair_lock>

    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(storage)
        defer { os_unfair_lock_unlock(storage) }
        return body()
    }
}
