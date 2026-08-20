import Foundation
import VoxPromptCore
@preconcurrency import AVFoundation
import CoreML
import Dispatch
import WhisperKit

actor Transcriber {

    // MARK: - État interne

    private var pipeline: WhisperKit?
    private var activeProfile: ComputeProfile?
    /// Identifiant du modèle effectivement chargé dans `pipeline` (peut différer des
    /// Préférences si l'utilisateur vient de changer de modèle sans recharger).
    private var loadedModel: String?
    /// Slot UNIQUE de chargement : téléchargement, sondage des profils, instanciation et
    /// réchauffage passent tous par là. Quiconque a besoin du pipeline attend cette tâche
    /// au lieu d'en lancer une seconde (deux `WhisperKit(config)` concurrents au premier
    /// lancement écrivaient le même `.incomplete` et corrompaient le modèle sur disque).
    private var loading: Task<Loaded, Error>?
    private var loadingID = 0
    /// Modèle visé par le chargement en cours, pour détecter un changement en vol.
    private var loadingModel: String?
    /// Incrémenté à chaque invalidation (reload, changement de modèle). Une tâche de
    /// chargement d'une génération périmée n'a plus le droit d'écrire l'état.
    private var loadGeneration = 0
    /// Date du dernier décodage réel ou warmup, pour décider si le moteur est « froid ».
    private var lastUsed: Date = .distantPast
    /// Exécuteur d'inférence dédié (hors pool coopératif). Remplacé après chaque gel.
    private var executorStorage: AnyObject?
    private var executorSerial = 0

    /// Stockage thread-safe du statut et du handler : `statusHandler` est `nonisolated`
    /// pour être posé depuis l'AppDelegate sans `await`.
    private let statusBox = EngineStatusBox()

    private enum Keys {
        // Anciennes clés (v1), lues une seule fois pour la migration.
        static let legacyProfile = "whisper.computeProfile"
        static let legacyOSBuild = "whisper.computeProfileOSBuild"
        // Clés v2 : le profil n'est valable que pour un couple (build macOS, modèle).
        static let profileID = "whisper.computeProfile.v2.id"
        static let profileOSBuild = "whisper.computeProfile.v2.osBuild"
        static let profileModel = "whisper.computeProfile.v2.model"
        static let profileDate = "whisper.computeProfile.v2.date"
        // Probation : on ne persiste une dégradation qu'après 2 timeouts consécutifs.
        static let probationID = "whisper.computeProfile.v2.probationID"
        static let probationCount = "whisper.computeProfile.v2.probationCount"
    }

    /// Au-delà, on re-sonde depuis le profil le plus rapide : Apple a pu corriger
    /// l'inférence entre-temps sans changer de build (mise à jour de firmware ANE,
    /// recompilation du cache CoreML), et un profil dégradé coûte cher en latence.
    private static let profileMaxAge: TimeInterval = 14 * 24 * 3600
    /// Watchdog du chargement (compilation CoreML incluse), hors téléchargement.
    private static let loadTimeoutSeconds: Double = 180
    /// Watchdog du décodage de bruit (warmup / sondage).
    private static let warmTimeoutSeconds: Double = 60

    // MARK: - Statut moteur (exposé à l'UI)

    enum EngineStatus: Equatable {
        case idle
        case downloading(progress: Double)
        case loading
        case warming
        case ready(profile: String)
        case failed(message: String)
    }

    /// Notifié sur le MAIN THREAD à chaque transition d'état. Poser le handler délivre
    /// immédiatement l'état courant, pour que l'UI se synchronise sans sonder.
    nonisolated var statusHandler: ((EngineStatus) -> Void)? {
        get { statusBox.handler }
        set { statusBox.handler = newValue }
    }

    /// Lecture synchrone du statut courant (utilisable depuis le main thread).
    nonisolated func currentStatus() -> EngineStatus { statusBox.status }

    // MARK: - Backend compute auto-adaptatif

    /// Une combinaison d'unités de calcul CoreML par étage du pipeline Whisper.
    struct ComputeProfile: Equatable {
        let id: String
        let label: String
        let mel: MLComputeUnits
        let audioEncoder: MLComputeUnits
        let textDecoder: MLComputeUnits
        let prefill: MLComputeUnits
        var options: ModelComputeOptions {
            ModelComputeOptions(
                melCompute: mel,
                audioEncoderCompute: audioEncoder,
                textDecoderCompute: textDecoder,
                prefillCompute: prefill
            )
        }
    }

    /// Profils candidats, du plus rapide au plus sûr.
    ///
    /// Contexte : sur macOS 26.5.x, l'inférence CoreML du DÉCODEUR Whisper se fige
    /// (deadlock natif : décodeur gelé avant le moindre token) à la fois sur l'Apple
    /// Neural Engine et sur le GPU/Metal. L'ENCODEUR audio, lui, n'est pas touché. Or
    /// c'est l'encodeur le composant lourd (≈85 % du temps de transcription sur CPU,
    /// mesuré : ~6 s pour 12 s d'audio, le décodage ne prenant que ~1 s). On remet donc
    /// l'encodeur sur le matériel rapide et on garde le décodeur (et le prefill) sur CPU.
    /// Si même l'encodeur déraille, on retombe sur GPU puis sur tout-CPU.
    ///
    /// Le profil retenu est mémorisé PAR BUILD macOS ET PAR MODÈLE : un profil validé sur
    /// Turbo ne prouve rien pour Large v3 (graphes CoreML différents). Le jour où Apple
    /// corrige l'inférence (nouveau build), le cache est invalidé, on re-teste depuis le
    /// plus rapide et l'app reprend automatiquement le plein régime, sans intervention.
    static let profiles: [ComputeProfile] = [
        ComputeProfile(id: "ane-encoder", label: "encodeur Neural Engine + décodeur CPU",
                       mel: .cpuOnly, audioEncoder: .cpuAndNeuralEngine, textDecoder: .cpuOnly, prefill: .cpuOnly),
        ComputeProfile(id: "gpu-encoder", label: "encodeur GPU + décodeur CPU",
                       mel: .cpuOnly, audioEncoder: .cpuAndGPU, textDecoder: .cpuOnly, prefill: .cpuOnly),
        ComputeProfile(id: "cpu-only", label: "tout CPU (filet de sécurité)",
                       mel: .cpuOnly, audioEncoder: .cpuOnly, textDecoder: .cpuOnly, prefill: .cpuOnly),
    ]

    private static func profile(byID id: String?) -> ComputeProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Migre les clés v1 vers v2. Le profil v1 avait été validé avec le modèle
    /// actuellement configuré : on le lui attribue, et on lui donne la date du jour pour
    /// ne pas déclencher un re-sondage immédiat au premier lancement de cette version.
    private static func migrateLegacyKeysIfNeeded(model: String) {
        let d = UserDefaults.standard
        guard d.string(forKey: Keys.profileID) == nil else { return }
        guard let legacyID = d.string(forKey: Keys.legacyProfile),
              let legacyBuild = d.string(forKey: Keys.legacyOSBuild),
              profile(byID: legacyID) != nil else { return }
        d.set(legacyID, forKey: Keys.profileID)
        d.set(legacyBuild, forKey: Keys.profileOSBuild)
        d.set(model, forKey: Keys.profileModel)
        d.set(Date().timeIntervalSince1970, forKey: Keys.profileDate)
        d.removeObject(forKey: Keys.legacyProfile)
        d.removeObject(forKey: Keys.legacyOSBuild)
        VPLog.log("migration cache profil v1 → v2 (\(legacyID), build \(legacyBuild), modèle \(model))")
    }

    /// Profil déjà validé pour CE build macOS ET CE modèle, et pas trop ancien.
    /// `nil` = il faut (re)sonder.
    private static func cachedProfile(model: String) -> ComputeProfile? {
        migrateLegacyKeysIfNeeded(model: model)
        let d = UserDefaults.standard
        guard d.string(forKey: Keys.profileOSBuild) == osBuild() else { return nil }
        guard d.string(forKey: Keys.profileModel) == model else { return nil }
        let stamp = d.double(forKey: Keys.profileDate)
        guard stamp > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - stamp
        if age > profileMaxAge {
            VPLog.log(String(format: "cache profil périmé (%.0f jours) : re-sondage", age / 86_400))
            return nil
        }
        return profile(byID: d.string(forKey: Keys.profileID))
    }

    private static func persistProfile(_ p: ComputeProfile, model: String) {
        let d = UserDefaults.standard
        d.set(p.id, forKey: Keys.profileID)
        d.set(osBuild(), forKey: Keys.profileOSBuild)
        d.set(model, forKey: Keys.profileModel)
        d.set(Date().timeIntervalSince1970, forKey: Keys.profileDate)
    }

    /// Build macOS courant (ex « 25F84 »). C'est ce qui change quand Apple publie un
    /// correctif, donc la bonne clé pour re-tester le matériel après une mise à jour.
    private static func osBuild() -> String {
        var size = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) != 0 || size == 0 { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname("kern.osversion", &buf, &size, nil, 0) != 0 { return "unknown" }
        return String(cString: buf)
    }

    // MARK: - Cache local du modèle

    private static func modelsRoot() -> URL? {
        // Même racine que HubApi (swift-transformers) : ~/Documents/huggingface.
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return docs
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// Dossier local du modèle s'il est présent ET complet, sinon `nil`.
    static func localModelFolder(_ identifier: String) -> URL? {
        guard let root = modelsRoot() else { return nil }
        let dir = root.appendingPathComponent(identifier, isDirectory: true)
        let fm = FileManager.default
        // Un modèle utilisable contient au minimum ces trois graphes compilés plus sa config.
        let requiredModels = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        for name in requiredModels {
            let marker = dir.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("coremldata.bin")
            guard fm.fileExists(atPath: marker.path) else { return nil }
        }
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return nil }
        return dir
    }

    /// Le modèle est-il déjà dans le cache local WhisperKit ? Utilisé par les Préférences
    /// pour signaler qu'un changement de modèle va déclencher un téléchargement.
    static func isModelDownloaded(_ identifier: String) -> Bool {
        localModelFolder(identifier) != nil
    }

    // MARK: - Erreurs

    enum TranscriberError: Error, CustomStringConvertible {
        /// Le décodeur n'a pas rendu la main dans le délai imparti (boucle bloquée avant
        /// même d'émettre un callback exploitable). Le HUD doit reprendre la main au lieu
        /// de tourner indéfiniment.
        case timeout(seconds: Double)
        /// Le modèle n'est ni sur disque ni téléchargeable (hors réseau, dépôt injoignable).
        case modelUnavailable(String)
        var description: String {
            switch self {
            case .timeout(let s): return String(format: "transcription timeout after %.0fs", s)
            case .modelUnavailable(let m): return "modèle indisponible : \(m)"
            }
        }
    }

    // MARK: - Cycle de vie du pipeline

    private struct Loaded {
        let kit: WhisperKit
        let profile: ComputeProfile
    }

    /// Point d'entrée UNIQUE vers le pipeline. Aucun autre chemin ne doit instancier
    /// `WhisperKit` : c'est ce qui garantit qu'un `keepWarm()` déclenché au keyDown ne
    /// lance pas un second chargement pendant le warmup de démarrage.
    private func ensureLoaded() async throws -> Loaded {
        let wanted = Settings.shared.modelIdentifier

        if let kit = pipeline, let p = activeProfile, loadedModel == wanted {
            return Loaded(kit: kit, profile: p)
        }
        if pipeline != nil, loadedModel != wanted {
            VPLog.log("modèle changé (\(loadedModel ?? "?") → \(wanted)) : invalidation du pipeline")
            invalidate()
        }
        if loading != nil, loadingModel != wanted {
            // Chargement déjà en vol, mais pour un AUTRE modèle (changement dans les Prefs
            // pendant le warmup de démarrage) : on l'abandonne au lieu d'attendre un
            // pipeline qui ne servira pas.
            VPLog.log("chargement en vol pour \(loadingModel ?? "?"), demandé \(wanted) : abandon")
            invalidate()
        }
        if let existing = loading { return try await existing.value }

        loadGeneration += 1
        let id = loadGeneration
        loadingID = id
        loadingModel = wanted
        let task = Task<Loaded, Error> { try await self.bootstrap(id: id, model: wanted) }
        loading = task
        do {
            let loaded = try await task.value
            if loadingID == id { loading = nil }
            return loaded
        } catch {
            if loadingID == id { loading = nil }
            throw error
        }
    }

    /// Séquence complète : téléchargement si besoin, choix du profil compute, chargement,
    /// réchauffage. Entièrement sérialisée par le slot `loading` : le sondage séquentiel
    /// des profils s'exécute donc lui aussi à un seul exemplaire.
    private func bootstrap(id: Int, model: String) async throws -> Loaded {
        let folder = try await ensureModelOnDisk(model)

        let cached = Self.cachedProfile(model: model)
        let candidates: [ComputeProfile]
        if let cached {
            VPLog.log("compute profile (cache) = \(cached.id) [\(cached.label)]")
            // Le cache d'abord, puis les profils plus sûrs en repli s'il ne charge plus.
            let safer = Self.profiles.drop(while: { $0 != cached }).dropFirst()
            candidates = [cached] + Array(safer)
        } else {
            VPLog.log("probing compute profiles for macOS build \(Self.osBuild()) / \(model)…")
            candidates = Self.profiles
        }

        var lastError: Error?
        for (rank, p) in candidates.enumerated() {
            guard loadGeneration == id else { throw CancellationError() }
            VPLog.log("chargement profil \(p.id)…")
            statusBox.emit(.loading)
            do {
                let t0 = Date()
                let kit = try await runIsolated(timeout: Self.loadTimeoutSeconds) {
                    try await Self.makePipeline(model: model, folder: folder, profile: p)
                }
                guard loadGeneration == id else { throw CancellationError() }
                VPLog.log(String(format: "pipeline init done in %.2fs (compute=%@)", Date().timeIntervalSince(t0), p.id))

                statusBox.emit(.warming)
                let t1 = Date()
                _ = try await runIsolated(timeout: Self.warmTimeoutSeconds) {
                    await Self.decodeNoise(kit)
                    return true
                }
                guard loadGeneration == id else { throw CancellationError() }
                VPLog.log(String(format: "decoder warmup done in %.2fs (compute=%@)", Date().timeIntervalSince(t1), p.id))

                pipeline = kit
                activeProfile = p
                loadedModel = model
                lastUsed = Date()
                // On ne rafraîchit PAS la date sur un simple hit de cache : c'est elle qui
                // fait expirer le profil au bout de 14 jours et redonne sa chance à l'ANE.
                if cached == nil || rank > 0 {
                    Self.persistProfile(p, model: model)
                    VPLog.log("compute profile selected = \(p.id) [\(p.label)]")
                }
                statusBox.emit(.ready(profile: p.label))
                return Loaded(kit: kit, profile: p)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                VPLog.log("profil \(p.id) KO (\(error)) : profil suivant")
                // Un timeout laisse peut-être un thread figé dans CoreML : on repart sur un
                // exécuteur neuf pour que le profil suivant ne soit pas contaminé.
                renewInferenceExecutor()
            }
        }

        let message: String
        if let err = lastError as? TranscriberError, case .modelUnavailable(let m) = err {
            message = m
        } else {
            message = "Aucun profil de calcul ne décode sur ce Mac"
        }
        statusBox.emit(.failed(message: message))
        VPLog.log("bootstrap échoué : \(message)")
        throw lastError ?? TranscriberError.timeout(seconds: Self.loadTimeoutSeconds)
    }

    /// Garantit la présence du modèle sur disque, avec progression. Le téléchargement
    /// n'est PAS sous watchdog (632 Mo peuvent légitimement prendre plusieurs minutes) ;
    /// c'est le chargement qui l'est.
    private func ensureModelOnDisk(_ model: String) async throws -> URL {
        if let local = Self.localModelFolder(model) { return local }
        VPLog.log("modèle \(model) absent du cache local : téléchargement")
        statusBox.emit(.downloading(progress: 0))
        let box = statusBox
        do {
            let url = try await WhisperKit.download(
                variant: model,
                progressCallback: { progress in
                    // Arrondi au pour cent : `emit` déduplique, donc pas d'inondation de l'UI.
                    let pct = (progress.fractionCompleted * 100).rounded() / 100
                    box.emit(.downloading(progress: max(0, min(1, pct))))
                }
            )
            VPLog.log("modèle téléchargé : \(url.path)")
            statusBox.emit(.loading)
            return url
        } catch {
            let message = "Modèle \(model) indisponible (réseau ?)"
            VPLog.log("download KO : \(error)")
            statusBox.emit(.failed(message: message))
            throw TranscriberError.modelUnavailable(message)
        }
    }

    private static func makePipeline(model: String, folder: URL, profile: ComputeProfile) async throws -> WhisperKit {
        VPLog.log("pipeline init start, model=\(model), compute=\(profile.id)")
        // `download: false` + `modelFolder` : le téléchargement a déjà eu lieu au-dessus,
        // avec progression. WhisperKit ne doit plus toucher au réseau ici.
        let config = WhisperKitConfig(
            model: model,
            modelFolder: folder.path,
            computeOptions: profile.options,
            download: false
        )
        return try await WhisperKit(config)
    }

    /// Invalide tout l'état de chargement (changement de modèle, reload, gel).
    private func invalidate() {
        loadGeneration += 1
        loading?.cancel()
        loading = nil
        loadingModel = nil
        pipeline = nil
        activeProfile = nil
        loadedModel = nil
    }

    /// Après un timeout, l'instance WhisperKit est suspecte : un de ses threads CoreML est
    /// probablement figé pour de bon. On la jette au lieu de la réutiliser.
    private func poisonPipeline() {
        VPLog.log("pipeline empoisonné (timeout) : instance jetée")
        pipeline = nil
        loadedModel = nil
        lastUsed = .distantPast
        renewInferenceExecutor()
    }

    // MARK: - API publique

    /// Appelé une fois au démarrage. Détermine (ou relit) le backend compute le plus
    /// rapide qui décode sans se figer, charge le pipeline et précompile le décodeur.
    /// Tourne en arrière-plan, donc n'impacte pas le temps de lancement perçu.
    func warmup() async {
        do {
            _ = try await ensureLoaded()
        } catch {
            VPLog.log("warmup error: \(error)")
        }
    }

    /// Réchauffe le moteur s'il n'a pas servi depuis un moment. Déclenché quand
    /// l'utilisateur commence à parler (keyDown) : le réchauffement se fait pendant la
    /// dictée, donc gratuit en temps perçu. No-op si le modèle est déjà chaud, pour
    /// épargner la batterie. Si un chargement est déjà en cours, on l'attend au lieu d'en
    /// démarrer un second.
    func keepWarm() async {
        guard Date().timeIntervalSince(lastUsed) > 90 else { return }
        guard let loaded = try? await ensureLoaded() else { return }
        // `ensureLoaded` a pu charger ET réchauffer : inutile de redécoder du bruit.
        guard Date().timeIntervalSince(lastUsed) > 90 else { return }
        VPLog.log("keep-warm (modèle froid depuis \(Int(Date().timeIntervalSince(lastUsed)))s)")
        statusBox.emit(.warming)
        do {
            _ = try await runIsolated(timeout: Self.warmTimeoutSeconds) {
                await Self.decodeNoise(loaded.kit)
                return true
            }
            lastUsed = Date()
            statusBox.emit(.ready(profile: loaded.profile.label))
        } catch {
            VPLog.log("keep-warm KO : \(error)")
            poisonPipeline()
            statusBox.emit(.idle)
        }
    }

    /// Abandonne le pipeline courant et recharge depuis `Settings.shared.modelIdentifier`.
    /// À appeler après un changement de modèle dans les Préférences.
    func reload() async {
        VPLog.log("reload demandé (modèle = \(Settings.shared.modelIdentifier))")
        invalidate()
        lastUsed = .distantPast
        renewInferenceExecutor()
        statusBox.emit(.idle)
        await warmup()
    }

    func transcribe(fileURL: URL) async throws -> String {
        VPLog.log("transcribe start file=\(fileURL.lastPathComponent)")
        let samples = try Self.loadFloatSamples(from: fileURL)
        return try await transcribe(samples: samples)
    }

    /// `promptText` : texte du segment PRÉCÉDENT (streaming). Injecté en `promptTokens`
    /// pour que le décodeur garde la casse, la ponctuation et le vocabulaire de la phrase
    /// en cours quand une coupe tombe en plein milieu.
    func transcribe(samples: [Float], promptText: String? = nil) async throws -> String {
        let t0 = Date()
        let loaded = try await ensureLoaded()
        let pipe = loaded.kit
        VPLog.log(String(format: "pipeline ready in %.2fs (compute=%@)", Date().timeIntervalSince(t0), loaded.profile.id))

        let audioSeconds = Double(samples.count) / 16_000.0
        VPLog.log(String(format: "audio samples=%d (%.1fs)", samples.count, audioSeconds))

        let language = Settings.shared.language
        let prompt = Self.promptInjectionEnabled
            ? Self.buildPromptTokens(pipe: pipe, previousText: promptText)
            : nil

        // Anti-loop guards. At temperature 0 the greedy decoder has no escape hatch if
        // it falls into a token-repetition cycle (frequent on macOS 26.x with the Turbo
        // model). The standard Whisper recipe is to define a temperature fallback ladder
        // plus compression/logprob thresholds: the decoder retries the segment at the
        // next temperature whenever the output's compression ratio exceeds 2.4 (typical
        // signature of repeated tokens) or the average log-probability drops below -1.0.
        // `withoutTimestamps: true` further reduces loops since the decoder no longer
        // has to interleave timestamp tokens that can themselves get stuck.
        //
        // `usePrefillCache` : WhisperKit désactive de lui-même le cache KV de prefill dès
        // que `promptTokens` est non nil (TextDecoder.swift, le cache démarre à l'index 0
        // et casserait avec un prompt devant). On le met donc explicitement à false quand
        // il y a un prompt, pour que le compromis soit visible plutôt que silencieux.
        // `usePrefillPrompt` reste à true : les tokens de prompt sont PRÉPENDÉS aux tokens
        // de prefill (langue / tâche / timestamps), les deux mécanismes cohabitent.
        let options = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: prompt == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: prompt,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
        VPLog.log("calling pipe.transcribe lang=\(language ?? "auto") promptTokens=\(prompt?.count ?? 0)")
        let t1 = Date()

        // Défense en profondeur, en plus du backend choisi à l'init :
        //   1. Détection de boucle DANS le callback, avec exigence de non-progrès sur 3
        //      callbacks : si le décodeur tourne vraiment en rond, on le coupe à la source.
        //   2. Watchdog timeout HORS du pool coopératif : si le décodage ne rend pas la
        //      main (deadlock natif insensible à l'annulation), on rend la main au HUD et
        //      on abandonne un thread dédié plutôt qu'un thread du pool.
        //   3. collapseRepetitions sur le texte final, pour nettoyer tout résidu.
        let timeoutSeconds = max(20.0, audioSeconds * 5.0)
        let monitor = RepetitionMonitor()

        let results: [TranscriptionResult]
        do {
            results = try await runIsolated(timeout: timeoutSeconds) {
                try await pipe.transcribe(audioArray: samples, decodeOptions: options, callback: { progress in
                    if Task.isCancelled { return false }            // coupé par le watchdog
                    if monitor.shouldAbort(progress.text) {
                        VPLog.log("repetition loop detected mid-decode (3 callbacks sans progrès) : aborting")
                        return false
                    }
                    VPLog.log("progress: \(progress.text.suffix(80))")
                    return nil
                })
            }
        } catch {
            VPLog.log("transcribe aborted: \(error)")
            if case TranscriberError.timeout = error {
                poisonPipeline()
                degradeProfile(from: loaded.profile)
                statusBox.emit(.idle)
            }
            throw error
        }

        VPLog.log(String(format: "whisper done in %.2fs segments=%d", Date().timeIntervalSince(t1), results.count))
        lastUsed = Date()
        Self.resetProbation()

        var results2 = results
        // Filet : un prompt initial peut faire rendre un segment VIDE par WhisperKit (voir
        // `promptInjectionEnabled`). Perdre une phrase en silence est le pire des scénarios,
        // donc on rejoue une fois sans prompt plutôt que de coller du vide.
        if prompt != nil, results.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            VPLog.log("résultat vide avec prompt initial : nouvel essai sans prompt")
            let retryOptions: DecodingOptions = {
                var o = options
                o.promptTokens = nil
                o.usePrefillCache = true
                return o
            }()
            results2 = (try? await runIsolated(timeout: timeoutSeconds) {
                try await pipe.transcribe(audioArray: samples, decodeOptions: retryOptions, callback: { _ in nil })
            }) ?? results
        }

        let raw = results2.map(\.text).joined(separator: " ")
        let deduped = TextCleanup.collapseRepetitions(raw)
        if deduped != raw {
            VPLog.log("collapsed repetitions: \(raw.count) → \(deduped.count) chars")
        }
        let corrected = TextCleanup.applyGlossary(deduped, glossary: TextCleanup.parseGlossary(Settings.shared.glossary))
        if corrected != deduped {
            VPLog.log("glossary applied: \"\(deduped.prefix(60))\" → \"\(corrected.prefix(60))\"")
        }
        return corrected
    }

    // MARK: - Prompt initial

    /// Injection du prompt initial (glossaire + fin du segment précédent) : DÉSACTIVÉE.
    ///
    /// MESURE du 20/08/2026, WhisperKit 0.18, Turbo 632 Mo, profil cpu-only, macOS 26.5.2
    /// (25F84), sur « Bonjour, ceci est un test » (2,2 s). Prompt = préfixes de longueur
    /// croissante de la même phrase, tout le reste identique :
    ///
    ///     0 token  -> "Bonjour, ceci est un test."
    ///     1 token  -> "Bonjour, ceci est un test."
    ///     2 tokens -> "Bonjour, ceci est un test."
    ///     3 tokens -> ""        <- décrochage
    ///     4, 5, 6, 8, 10, 13 tokens -> ""
    ///
    /// Le décrochage est indépendant du contenu (glossaire court, phrase avec ou sans
    /// virgule finale : idem) et indépendant des options testées (`withoutTimestamps`
    /// true/false, `chunkingStrategy` vad/none, seuils de repli désactivés,
    /// `suppressBlank: false`). Diagnostic : passé 2 tokens forcés, le décodeur prédit
    /// `<|endoftext|>` dès la sortie du prompt et le segment ressort vide.
    ///
    /// Le conflit avec `usePrefillPrompt` est réel : avec `usePrefillPrompt: false` le
    /// texte revient, mais les tokens de langue et de tâche ne sont alors plus forcés, ce
    /// qui rend la langue non déterministe. `prefixTokens` fonctionne mécaniquement mais
    /// FORCE le prompt dans la sortie (le texte du segment précédent serait recollé).
    ///
    /// Conséquence : on garde le découpage amélioré (coupe au creux d'énergie RMS) et la
    /// correction du glossaire en post-traitement. La construction du prompt reste écrite
    /// et testée juste en dessous : quand WhisperKit corrigera le bookkeeping du cache KV
    /// avec prompt forcé, il suffira de repasser ce drapeau à `true` (le filet de reprise
    /// sans prompt dans `transcribe` couvre déjà la régression).
    private static let promptInjectionEnabled = false

    /// Construit les `promptTokens` du segment.
    ///
    /// Deux apports, dans cet ordre :
    ///   1. le GLOSSAIRE (100 tokens max), pour que Whisper connaisse les noms propres et
    ///      le jargon AVANT de décoder. C'est ce que promettait le commentaire de
    ///      `Settings.glossary` et qui n'existait pas : la correction n'arrivait qu'après
    ///      coup, en distance d'édition ;
    ///   2. les 200 derniers caractères du segment précédent, pour la continuité de casse
    ///      et de ponctuation quand une coupe tombe en plein milieu d'une phrase.
    ///
    /// WhisperKit tronque de lui-même à `maxTokenContext / 2 - 1` en gardant le SUFFIXE :
    /// en cas de dépassement c'est donc le glossaire qui saute en premier, et la
    /// continuité de phrase (plus critique pour le rendu) qui survit.
    private static func buildPromptTokens(pipe: WhisperKit, previousText: String?) -> [Int]? {
        guard let tokenizer = pipe.tokenizer else { return nil }
        var tokens: [Int] = []

        let glossary = TextCleanup.parseGlossary(Settings.shared.glossary)
        if !glossary.isEmpty {
            let phrase = glossary.joined(separator: ", ")
            tokens.append(contentsOf: tokenizer.encode(text: " " + phrase).suffix(100))
        }
        if let previousText {
            let tail = String(previousText.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                tokens.append(contentsOf: tokenizer.encode(text: " " + tail))
            }
        }
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: - Dégradation de profil (avec probation)

    /// Rétrograde vers le profil suivant (plus sûr), mais seulement au DEUXIÈME timeout
    /// consécutif sur le même profil. Un gel isolé (pression mémoire, cache CoreML évincé)
    /// ne doit pas condamner définitivement l'accélération matérielle.
    private func degradeProfile(from current: ComputeProfile) {
        let d = UserDefaults.standard
        let model = Settings.shared.modelIdentifier
        var count = d.integer(forKey: Keys.probationCount)
        count = (d.string(forKey: Keys.probationID) == current.id) ? count + 1 : 1
        d.set(current.id, forKey: Keys.probationID)
        d.set(count, forKey: Keys.probationCount)

        guard count >= 2 else {
            VPLog.log("timeout #1 sur \(current.id) : probation, profil conservé")
            return
        }
        guard let idx = Self.profiles.firstIndex(of: current), idx + 1 < Self.profiles.count else {
            VPLog.log("degrade: déjà au profil le plus sûr (\(current.id))")
            Self.resetProbation()
            return
        }
        let next = Self.profiles[idx + 1]
        Self.persistProfile(next, model: model)
        activeProfile = next
        Self.resetProbation()
        VPLog.log("degrade compute profile \(current.id) → \(next.id) (2 timeouts consécutifs)")
    }

    private static func resetProbation() {
        let d = UserDefaults.standard
        guard d.string(forKey: Keys.probationID) != nil || d.integer(forKey: Keys.probationCount) != 0 else { return }
        d.removeObject(forKey: Keys.probationID)
        d.removeObject(forKey: Keys.probationCount)
    }

    // MARK: - Warmup décodeur

    /// Décode 2 s de bruit faible pour précompiler/réchauffer le graphe CoreML du décodeur
    /// (coûteux uniquement au 1er décodage à froid). Résultat jeté. `sampleLength: 4` borne
    /// le décodage à quelques tokens : assez pour compiler le graphe, sans halluciner des
    /// centaines de tokens sur du bruit.
    private static func decodeNoise(_ pipe: WhisperKit) async {
        var noise = [Float](repeating: 0, count: 16_000 * 2)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<noise.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.1
        }
        let warmOptions = DecodingOptions(
            verbose: false, task: .transcribe, language: Settings.shared.language,
            temperature: 0.0, sampleLength: 4, usePrefillPrompt: true, skipSpecialTokens: true,
            withoutTimestamps: true, noSpeechThreshold: 1.0, chunkingStrategy: ChunkingStrategy.none
        )
        _ = try? await pipe.transcribe(audioArray: noise, decodeOptions: warmOptions, callback: { _ in nil })
    }

    // MARK: - Exécution isolée + watchdog

    /// Exécuteur d'inférence courant, créé à la demande.
    ///
    /// POURQUOI : `WhisperKit(config)` compile les graphes CoreML sur le thread appelant,
    /// et `transcribe` bloque son thread pendant l'inférence. Sur le pool coopératif Swift
    /// (largeur = nombre de cœurs), un deadlock CoreML confisquait donc DÉFINITIVEMENT un
    /// thread du pool : après quelques gels, plus rien ne tournait dans l'app, ni le HUD,
    /// ni le collage, ni la hotkey. On déporte l'inférence sur une file GCD à nous ; un gel
    /// n'y coûte qu'un thread, et on remplace la file entière au gel suivant.
    @available(macOS 15.0, *)
    private func inferenceExecutor() -> InferenceExecutor {
        if let existing = executorStorage as? InferenceExecutor { return existing }
        executorSerial += 1
        let fresh = InferenceExecutor(label: "fr.voxprompt.inference.\(executorSerial)")
        executorStorage = fresh
        return fresh
    }

    /// Abandonne l'exécuteur courant : la tâche figée garde son thread, les suivantes
    /// repartent sur une file neuve.
    private func renewInferenceExecutor() {
        guard executorStorage != nil else { return }
        executorStorage = nil
        VPLog.log("exécuteur d'inférence renouvelé (l'ancien garde son thread figé)")
    }

    /// Exécute `work` hors du pool coopératif quand la plateforme le permet, sous watchdog.
    ///
    /// Repli macOS 14 / 15.0 à 15.3 : `withTaskExecutorPreference` (ou la conformance
    /// `DispatchQueue: TaskExecutor`) n'existe pas, on retombe sur l'ancien comportement
    /// (`Task.detached` sur le pool coopératif). Le bug CoreML visé est spécifique à
    /// macOS 26.5.x, donc les machines concernées bénéficient toutes de l'isolation.
    private func runIsolated<T: Sendable>(
        timeout: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if #available(macOS 15.0, *) {
            let executor = inferenceExecutor()
            return try await Self.runWithTimeout(seconds: timeout) {
                try await withTaskExecutorPreference(executor) {
                    try await work()
                }
            }
        }
        return try await Self.runWithTimeout(seconds: timeout, work)
    }

    /// Exécute `work` avec un délai maximum. À la différence d'un `withThrowingTaskGroup`,
    /// qui attendrait la fin de toutes ses tâches enfants à la sortie (et resterait donc
    /// lui-même bloqué si le décodage est figé sur un deadlock natif insensible à
    /// l'annulation), on résout ici la continuation dès le premier des deux événements :
    /// fin du travail OU expiration du délai. En cas de timeout, la tâche de travail est
    /// annulée puis simplement abandonnée en arrière-plan ; `transcribe()` rend la main et
    /// le HUD se débloque au lieu de tourner à l'infini. Le garde `ResumeOnce` empêche tout
    /// double `resume` de la continuation (qui ferait crasher l'app).
    ///
    /// La tâche de minuterie est ANNULÉE dès que le travail aboutit : elle vivait sinon
    /// jusqu'à l'échéance complète (300 s pour 60 s d'audio), à retenir une continuation et
    /// un créneau de sommeil pour rien.
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = ResumeOnce()
        let timer = CancelBox()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let workTask = Task.detached(priority: .userInitiated) {
                do {
                    let value = try await work()
                    if await gate.claim() { timer.cancel(); cont.resume(returning: value) }
                } catch {
                    if await gate.claim() { timer.cancel(); cont.resume(throwing: error) }
                }
            }
            let timerTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return                                   // annulée : le travail a abouti
                }
                if await gate.claim() {
                    workTask.cancel()
                    cont.resume(throwing: TranscriberError.timeout(seconds: seconds))
                }
            }
            timer.arm(timerTask)
        }
    }

    // MARK: - Chargement audio

    private static func loadFloatSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "VoxPrompt.Audio", code: 1)
        }
        if file.processingFormat.sampleRate == 16_000,
           file.processingFormat.channelCount == 1 {
            try file.read(into: buffer)
        } else {
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                throw NSError(domain: "VoxPrompt.Audio", code: 2)
            }
            try file.read(into: src)
            var err: NSError?
            var consumed = false
            converter.convert(to: buffer, error: &err) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return src
            }
            if let err { throw err }
        }
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "VoxPrompt.Audio", code: 3)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: - Alias de compatibilité (logique déplacée dans TextCleanup, testable)

    static func collapseRepetitions(_ text: String) -> String {
        TextCleanup.collapseRepetitions(text)
    }

    static func isRepetitionLoop(_ text: String) -> Bool {
        TextCleanup.isRepetitionLoop(text)
    }
}

// MARK: - Utilitaires de concurrence

/// Garde à usage unique : `claim()` ne renvoie `true` qu'une seule fois, pour les autres
/// appels `false`. Permet à deux tâches concurrentes (le travail et le timeout) de se
/// disputer le droit de résoudre une `CheckedContinuation` sans jamais la résoudre deux fois.
actor ResumeOnce {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Porte-tâche annulable, tolérant à l'ordre : si `cancel()` arrive avant `arm()`
/// (travail terminé avant même que la minuterie soit posée), la tâche est annulée
/// dès qu'elle est confiée.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func arm(_ t: Task<Void, Never>) {
        lock.lock()
        if cancelled { lock.unlock(); t.cancel(); return }
        task = t
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }
}

/// Exécuteur de tâches adossé à une file GCD concurrente dédiée, HORS du pool coopératif
/// Swift. Les fonctions `async` non isolées exécutées sous `withTaskExecutorPreference`
/// (y compris les groupes de tâches internes de WhisperKit) tournent sur cette file.
@available(macOS 15.0, *)
final class InferenceExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        // Concurrente : le découpage VAD de WhisperKit lance plusieurs fenêtres en
        // parallèle, et une file série les sérialiserait derrière un éventuel gel.
        queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        // `asUnownedTaskExecutor()` ne retient PAS : on capture `self` fortement pour que
        // l'exécuteur survive à ses travaux en file, y compris après avoir été abandonné
        // (renouvellement post-gel), sinon un job en vol référencerait un objet libéré.
        queue.async { [self] in unowned.runSynchronously(on: asUnownedTaskExecutor()) }
    }
}

/// Stockage thread-safe du statut moteur et de son handler. Le handler est TOUJOURS
/// appelé sur le main thread, en respectant l'ordre des transitions.
final class EngineStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: ((Transcriber.EngineStatus) -> Void)?
    private var _status: Transcriber.EngineStatus = .idle

    var status: Transcriber.EngineStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    var handler: ((Transcriber.EngineStatus) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            let current = _status
            lock.unlock()
            // Délivre l'état courant tout de suite : l'UI se synchronise sans sonder.
            guard let newValue else { return }
            DispatchQueue.main.async { newValue(current) }
        }
    }

    func emit(_ new: Transcriber.EngineStatus) {
        lock.lock()
        guard new != _status else { lock.unlock(); return }
        _status = new
        let handler = _handler
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler(new) }
    }
}
