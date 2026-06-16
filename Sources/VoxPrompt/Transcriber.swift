import Foundation
import AVFoundation
import CoreML
import WhisperKit

actor Transcriber {
    private var pipeline: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private var activeProfile: ComputeProfile?
    /// Date du dernier décodage réel ou warmup, pour décider si le moteur est "froid".
    private var lastUsed: Date = .distantPast

    private enum Keys {
        static let computeProfile = "whisper.computeProfile"
        static let computeProfileOSBuild = "whisper.computeProfileOSBuild"
    }

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
    /// Le profil retenu est mémorisé PAR BUILD macOS (`kern.osversion`). Le jour où Apple
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

    /// Profil déjà validé POUR CE BUILD macOS, sinon nil (il faudra le déterminer).
    private static func cachedProfile() -> ComputeProfile? {
        let d = UserDefaults.standard
        guard d.string(forKey: Keys.computeProfileOSBuild) == osBuild() else { return nil }
        return profile(byID: d.string(forKey: Keys.computeProfile))
    }

    private static func persist(_ p: ComputeProfile) {
        let d = UserDefaults.standard
        d.set(p.id, forKey: Keys.computeProfile)
        d.set(osBuild(), forKey: Keys.computeProfileOSBuild)
    }

    /// Build macOS courant (ex "25F80"). C'est ce qui change quand Apple publie un correctif,
    /// donc la bonne clé pour re-tester le matériel après une mise à jour système.
    private static func osBuild() -> String {
        var size = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) != 0 || size == 0 { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname("kern.osversion", &buf, &size, nil, 0) != 0 { return "unknown" }
        return String(cString: buf)
    }

    // MARK: - Cycle de vie du pipeline

    private func makePipeline(profile: ComputeProfile) async throws -> WhisperKit {
        VPLog.log("pipeline init start, model=\(Settings.shared.modelIdentifier), compute=\(profile.id)")
        let config = WhisperKitConfig(model: Settings.shared.modelIdentifier, computeOptions: profile.options)
        let kit = try await WhisperKit(config)
        VPLog.log("pipeline init done (compute=\(profile.id))")
        return kit
    }

    private func ensurePipeline() async throws -> WhisperKit {
        if let p = pipeline { return p }
        if let existing = loading { return try await existing.value }
        let profile = activeProfile ?? Self.cachedProfile() ?? Self.profiles[0]
        let task = Task { try await self.makePipeline(profile: profile) }
        loading = task
        do {
            let p = try await task.value
            pipeline = p
            activeProfile = profile
            loading = nil
            return p
        } catch {
            loading = nil
            throw error
        }
    }

    /// Appelé une fois au démarrage. Détermine (ou relit) le backend compute le plus rapide
    /// qui décode sans se figer, charge le pipeline et précompile le décodeur. Tourne en
    /// arrière-plan, donc n'impacte pas le temps de lancement perçu.
    func warmup() async {
        // 1) Profil déjà validé pour ce build macOS : on l'utilise sans re-tester.
        if let cached = Self.cachedProfile() {
            VPLog.log("compute profile (cache) = \(cached.id) [\(cached.label)]")
            await loadAndWarm(cached)
            return
        }
        // 2) Sinon, on sonde du plus rapide au plus sûr et on mémorise le premier sain.
        VPLog.log("probing compute profiles for macOS build \(Self.osBuild())…")
        for p in Self.profiles {
            VPLog.log("probing \(p.id)…")
            if await probe(p) {
                Self.persist(p)
                VPLog.log("compute profile selected = \(p.id) [\(p.label)]")
                return
            }
            VPLog.log("\(p.id) KO (figé/timeout) — profil suivant")
            pipeline = nil
            loading = nil
            activeProfile = nil
        }
        VPLog.log("aucun profil n'a décodé — fallback CPU sans cache")
        await loadAndWarm(Self.profiles.last!)
    }

    /// Tente un profil : charge le pipeline et décode un court bruit sous watchdog. Renvoie
    /// true si le décodage rend la main dans le délai (profil sain), false s'il se fige.
    /// Délai généreux (60 s) : un deadlock ne rend JAMAIS la main, tandis qu'une première
    /// compilation ANE légitime peut être longue ; on ne veut pas la confondre avec un blocage.
    private func probe(_ p: ComputeProfile) async -> Bool {
        do {
            let kit = try await makePipeline(profile: p)
            let t = Date()
            _ = try await Self.runWithTimeout(seconds: 60) {
                await Self.decodeNoise(kit)
                return true
            }
            VPLog.log(String(format: "probe %@ OK in %.2fs", p.id, Date().timeIntervalSince(t)))
            pipeline = kit
            activeProfile = p
            lastUsed = Date()
            return true
        } catch {
            VPLog.log("probe \(p.id) failed: \(error)")
            return false
        }
    }

    private func loadAndWarm(_ p: ComputeProfile) async {
        do {
            let kit = try await makePipeline(profile: p)
            pipeline = kit
            activeProfile = p
            let t = Date()
            await Self.decodeNoise(kit)
            lastUsed = Date()
            VPLog.log(String(format: "decoder warmup done in %.2fs (compute=%@)", Date().timeIntervalSince(t), p.id))
        } catch {
            VPLog.log("warmup error: \(error)")
        }
    }

    /// Réchauffe le moteur s'il n'a pas servi depuis un moment. Déclenché quand l'utilisateur
    /// commence à parler (keyDown) : le réchauffement se fait pendant la dictée, donc gratuit
    /// en temps perçu. No-op si le modèle est déjà chaud, pour épargner la batterie.
    func keepWarm() async {
        guard Date().timeIntervalSince(lastUsed) > 90 else { return }
        guard let kit = try? await ensurePipeline() else { return }
        VPLog.log("keep-warm (modèle froid depuis \(Int(Date().timeIntervalSince(lastUsed)))s)")
        await Self.decodeNoise(kit)
        lastUsed = Date()
    }

    /// Rétrograde vers le profil suivant (plus sûr) et le mémorise. Appelé si une vraie
    /// transcription se fige malgré tout (filet réactif en plus du sondage au démarrage).
    private func degradeProfile() {
        let current = activeProfile ?? Self.cachedProfile() ?? Self.profiles[0]
        guard let idx = Self.profiles.firstIndex(of: current), idx + 1 < Self.profiles.count else {
            VPLog.log("degrade: déjà au profil le plus sûr (\(current.id))")
            return
        }
        let next = Self.profiles[idx + 1]
        Self.persist(next)
        activeProfile = next
        pipeline = nil
        loading = nil
        VPLog.log("degrade compute profile \(current.id) → \(next.id) (timeout)")
    }

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

    enum TranscriberError: Error, CustomStringConvertible {
        /// Le décodeur n'a pas rendu la main dans le délai imparti (boucle bloquée avant
        /// même d'émettre un callback exploitable). Le HUD doit reprendre la main au lieu
        /// de tourner indéfiniment.
        case timeout(seconds: Double)
        var description: String {
            switch self {
            case .timeout(let s): return String(format: "transcription timeout after %.0fs", s)
            }
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        let t0 = Date()
        VPLog.log("transcribe start file=\(fileURL.lastPathComponent)")
        let pipe = try await ensurePipeline()
        VPLog.log(String(format: "pipeline ready in %.2fs (compute=%@)", Date().timeIntervalSince(t0), activeProfile?.id ?? "?"))

        let samples = try Self.loadFloatSamples(from: fileURL)
        let audioSeconds = Double(samples.count) / 16_000.0
        VPLog.log(String(format: "audio loaded samples=%d (%.1fs)", samples.count, audioSeconds))

        let language = Settings.shared.language
        // Anti-loop guards. At temperature 0 the greedy decoder has no escape hatch if
        // it falls into a token-repetition cycle (frequent on macOS 26.x with the Turbo
        // model). The standard Whisper recipe is to define a temperature fallback ladder
        // plus compression/logprob thresholds: the decoder retries the segment at the
        // next temperature whenever the output's compression ratio exceeds 2.4 (typical
        // signature of repeated tokens) or the average log-probability drops below -1.0.
        // `withoutTimestamps: true` further reduces loops since the decoder no longer
        // has to interleave timestamp tokens that can themselves get stuck.
        let options = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
        VPLog.log("calling pipe.transcribe lang=\(language ?? "auto")")
        let t1 = Date()

        // Défense en profondeur, en plus du backend choisi à l'init :
        //   1. Détection de boucle DANS le callback : si le décodeur se met malgré tout à
        //      répéter un n-gramme, on renvoie `false` pour le couper à la source.
        //   2. Watchdog timeout : si le décodage ne rend pas la main dans un délai borné
        //      (deadlock natif qui ne répond ni à l'annulation ni au callback), on rend la
        //      main au HUD, on rétrograde le profil compute et on abandonne la tâche figée.
        //   3. collapseRepetitions sur le texte final, pour nettoyer tout résidu.
        let timeoutSeconds = max(20.0, audioSeconds * 5.0)

        let results: [TranscriptionResult]
        do {
            results = try await Self.runWithTimeout(seconds: timeoutSeconds) {
                try await pipe.transcribe(audioArray: samples, decodeOptions: options, callback: { progress in
                    if Task.isCancelled { return false }            // coupé par le watchdog
                    if Self.isRepetitionLoop(progress.text) {
                        VPLog.log("repetition loop detected mid-decode — aborting")
                        return false                                 // filet 1 : coupe à la source
                    }
                    VPLog.log("progress: \(progress.text.suffix(80))")
                    return nil
                })
            }
        } catch {
            VPLog.log("transcribe aborted: \(error)")
            if case TranscriberError.timeout = error { degradeProfile() }
            throw error
        }

        VPLog.log(String(format: "whisper done in %.2fs segments=%d", Date().timeIntervalSince(t1), results.count))
        lastUsed = Date()
        let raw = results.map(\.text).joined(separator: " ")
        let deduped = Self.collapseRepetitions(raw)
        if deduped != raw {
            VPLog.log("collapsed repetitions: \(raw.count) → \(deduped.count) chars")
        }
        let corrected = Self.applyGlossary(deduped)
        if corrected != deduped {
            VPLog.log("glossary applied: \"\(deduped.prefix(60))\" → \"\(corrected.prefix(60))\"")
        }
        return corrected
    }

    /// Exécute `work` avec un délai maximum. À la différence d'un `withThrowingTaskGroup`,
    /// qui attendrait la fin de toutes ses tâches enfants à la sortie (et resterait donc
    /// lui-même bloqué si le décodage est figé sur un deadlock natif insensible à
    /// l'annulation), on résout ici la continuation dès le premier des deux événements :
    /// fin du travail OU expiration du délai. En cas de timeout, la tâche de travail est
    /// annulée puis simplement abandonnée en arrière-plan ; `transcribe()` rend la main et
    /// le HUD se débloque au lieu de tourner à l'infini. Le garde `ResumeOnce` empêche tout
    /// double `resume` de la continuation (qui ferait crasher l'app).
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let workTask = Task.detached(priority: .userInitiated) {
                do {
                    let value = try await work()
                    if await gate.claim() { cont.resume(returning: value) }
                } catch {
                    if await gate.claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if await gate.claim() {
                    workTask.cancel()
                    cont.resume(throwing: TranscriberError.timeout(seconds: seconds))
                }
            }
        }
    }

    /// Détecte une boucle de répétition du décodeur : un même motif de 1 à 6 mots répété
    /// au moins 4 fois consécutivement en fin de texte. Signature typique d'un décodage
    /// Whisper emballé ("merci merci merci…" ou "je vais je vais je vais…"). Appelée à
    /// chaque callback pour couper le décodage à la source.
    static func isRepetitionLoop(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { $0.lowercased() }
        guard words.count >= 8 else { return false }
        let tail = Array(words.suffix(60))
        let n = tail.count
        for size in 1...6 {
            guard n >= size * 4 else { continue }
            let pattern = Array(tail.suffix(size))
            var reps = 1
            var idx = n - size
            while idx - size >= 0 {
                if Array(tail[(idx - size)..<idx]) == pattern {
                    reps += 1
                    idx -= size
                    if reps >= 4 { return true }
                } else {
                    break
                }
            }
        }
        return false
    }

    /// Réduit à une seule occurrence tout motif de 1 à 6 mots répété au moins 3 fois
    /// consécutivement. Nettoie le résidu d'une boucle de décodage sans abîmer un
    /// doublement volontaire ("très très bien", qui ne déclenche qu'à partir de 3).
    /// Renvoie le texte original intact si rien n'est répété.
    static func collapseRepetitions(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 6 else { return text }
        var touched = false
        var changed = true
        while changed {
            changed = false
            // Du plus petit motif au plus grand : une répétition mono-mot ("prêt prêt
            // prêt…") doit s'effondrer entièrement avant qu'un bigramme ne la capture
            // partiellement (sinon 6 mots identiques se réduisent à 2 au lieu de 1).
            for size in 1...6 {
                var i = 0
                while i + size * 3 <= words.count {
                    let pattern = words[i..<i+size].map { $0.lowercased() }
                    var reps = 1
                    var j = i + size
                    while j + size <= words.count,
                          words[j..<j+size].map({ $0.lowercased() }) == pattern {
                        reps += 1
                        j += size
                    }
                    if reps >= 3 {
                        words.removeSubrange((i + size)..<(i + size * reps))
                        changed = true
                        touched = true
                    }
                    // Avance d'un seul mot (et non d'un motif entier) pour ne jamais rater
                    // l'alignement de phase d'une répétition décalée ("on y va on y va…"
                    // capté à partir du bon mot plutôt que de "y va on").
                    i += 1
                }
                if changed { break }
            }
        }
        return touched ? words.joined(separator: " ") : text
    }

    private static func applyGlossary(_ text: String) -> String {
        let items = Settings.shared.glossary
            .components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        guard !items.isEmpty else { return text }

        // Split en tokens en préservant ponctuation et espaces
        var output = ""
        var buffer = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" {
                buffer.append(ch)
            } else {
                if !buffer.isEmpty {
                    output.append(replace(word: buffer, glossary: items))
                    buffer = ""
                }
                output.append(ch)
            }
        }
        if !buffer.isEmpty {
            output.append(replace(word: buffer, glossary: items))
        }
        return output
    }

    private static func replace(word: String, glossary: [String]) -> String {
        guard word.count >= 3 else { return word }
        let wLower = word.lowercased()
        var best: (item: String, distance: Int)? = nil
        for item in glossary {
            let iLower = item.lowercased()
            if wLower == iLower { return item }  // déjà bon
            // Tolérance : 1 pour 3-5 lettres, 2 pour 6-8, 3 pour 9+
            let maxDist = max(1, item.count / 4)
            let d = levenshtein(wLower, iLower)
            if d <= maxDist {
                if best == nil || d < best!.distance {
                    best = (item, d)
                }
            }
        }
        return best?.item ?? word
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let m = aChars.count, n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

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
}

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
