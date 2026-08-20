import Foundation
import VoxPromptCore

/// Transcription en continu pendant la dictée : reçoit les samples 16 kHz mono produits
/// par l'AudioRecorder au fil de l'eau, découpe le flux sur les pauses naturelles et
/// transcrit chaque segment en arrière-plan PENDANT que l'utilisateur parle. Au
/// relâchement de la touche, seul le dernier segment reste à transcrire : la latence
/// perçue tombe de "durée totale de la dictée" à "durée de la dernière phrase".
///
/// Le WAV complet continue d'être écrit par l'AudioRecorder en parallèle : si un segment
/// échoue (timeout décodeur, erreur pipeline), `finish()` renvoie nil et l'appelant
/// retombe sur la transcription batch du fichier, comportement historique.
final class StreamingSession {
    private let transcriber: Transcriber
    private let lock = NSLock()

    // État protégé par `lock`. `ingest` arrive sur le thread temps réel du tap audio,
    // `finish` sur le main thread, les résultats sur des Tasks concurrents. TOUTE la
    // section critique (lecture de `chain` + création de la tâche + réécriture de `chain`)
    // se fait sous le MÊME verrou : deux verrouillages séparés laissaient une coupe
    // naturelle et `finish()` créer deux tâches qui lisaient le même `previous`, donc
    // deux segments décodés en parallèle dont un seul était attendu. Une phrase entière
    // disparaissait alors en silence.
    private var pending: [Float] = []      // samples du segment en cours (pas encore transcrits)
    private var silentRun = 0              // samples consécutifs sous le seuil de silence
    private var texts: [String?] = []      // résultats ordonnés par segment (nil = en cours)
    private var chain: Task<Void, Never>?  // sérialise les transcriptions, préserve l'ordre
    private var tasks: [Task<Void, Never>] = []  // TOUTES les tâches en vol, pour `finish()`
    private var failed = false
    private var finished = false
    private var segmentCount = 0

    // Découpage : une pause de 250 ms coupe un segment d'au moins 2,5 s ; au-delà d'une
    // durée de parole ininterrompue (voir `maxSegmentSamples`, adaptée au moteur de calcul)
    // on coupe quand même, ce qui borne la latence du dernier segment et la mémoire.
    // Le seuil RMS est aligné sur le garde anti-hallucination du batch (0.003),
    // légèrement relevé car une pause entre deux phrases n'est jamais un silence parfait.
    private static let sampleRate = 16_000
    private static let silenceThreshold: Float = 0.004
    private static let minSilenceSamples = sampleRate / 4        // 250 ms
    private static let minSegmentSamples = sampleRate * 5 / 2    // 2,5 s
    private static let maxSegmentSecondsFast = 12
    /// Sur un profil lent, le decodage tourne MOINS VITE que le temps reel (mesure : 9,3 s
    /// pour 6,5 s d'audio en tout-CPU). Attendre 12 s de parole ininterrompue avant de
    /// couper reporte alors tout le travail apres le relachement, ce qui annule l'interet
    /// du streaming. On coupe plus tot pour que le decodage demarre pendant que l'utilisateur
    /// parle encore, au prix d'un peu de contexte pour le modele.
    private static let maxSegmentSecondsSlow = 5
    private static let minTailSamples = sampleRate / 4           // tail < 250 ms : rien à dire
    private static let cutWindowSamples = sampleRate / 50        // 20 ms
    private static let cutLookbackSamples = sampleRate           // 1 s

    /// Longueur maximale d'un segment avant coupe forcee, choisie a l'ouverture de la
    /// session selon le moteur de calcul reellement actif.
    private let maxSegmentSamples: Int

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
        // Le profil retenu par le Transcriber est memorise par build macOS et par modele.
        // `cpu-only` signifie que le bug CoreML d'Apple nous prive de l'ANE et du GPU.
        let profile = UserDefaults.standard.string(forKey: "whisper.computeProfile.v2.id")
        let seconds = (profile == "cpu-only") ? Self.maxSegmentSecondsSlow : Self.maxSegmentSecondsFast
        self.maxSegmentSamples = Self.sampleRate * seconds
    }

    /// Appelé par l'AudioRecorder pour chaque buffer converti (thread du tap audio).
    /// Doit rester léger : append + RMS du bloc + décision de coupe.
    func ingest(_ samples: [Float]) {
        lock.lock()
        guard !finished, !failed else { lock.unlock(); return }
        pending.append(contentsOf: samples)

        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (Float(samples.count) > 0) ? sqrtf(sum / Float(samples.count)) : 0
        if rms < Self.silenceThreshold {
            silentRun += samples.count
        } else {
            silentRun = 0
        }

        let naturalCut = pending.count >= Self.minSegmentSamples && silentRun >= Self.minSilenceSamples
        let forcedCut = pending.count >= maxSegmentSamples
        guard naturalCut || forcedCut else { lock.unlock(); return }

        let isForced = forcedCut && !naturalCut
        // Coupe forcée : jamais à l'instant exact (souvent en plein mot), mais au creux
        // d'énergie de la dernière seconde. Le reliquat repart dans le segment suivant.
        let cutIndex = isForced ? Self.bestCutIndex(pending) : pending.count
        let segment = Array(pending[..<cutIndex])
        pending.removeFirst(cutIndex)
        silentRun = 0
        let note = enqueueLocked(segment, reason: isForced ? "forced" : "pause")
        lock.unlock()

        if let note { VPLog.log(note) }
    }

    /// Fin de dictée : transcrit la queue restante, attend les segments en vol et renvoie
    /// le texte complet. nil = un segment a échoué, l'appelant doit retomber sur le batch.
    func finish() async -> String? {
        // Sections critiques déportées dans des helpers SYNCHRONES : un verrou ne doit
        // jamais être pris dans une fonction `async` (règle Swift 6, warning en mode 5).
        let (alreadyFailed, note) = closeAndEnqueueTail()
        if let note { VPLog.log(note) }
        if alreadyFailed { return nil }

        // Attendre TOUTES les tâches, pas seulement la dernière : la boucle vide le
        // tableau sous verrou et recommence tant qu'il en est arrivé de nouvelles.
        while true {
            let batch = drainTasks()
            if batch.isEmpty { break }
            for task in batch { await task.value }
        }

        return assembleText()
    }

    /// Ferme la session, met la queue restante en file et dit si un segment avait déjà échoué.
    private func closeAndEnqueueTail() -> (failed: Bool, note: String?) {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        let tail = pending
        pending = []
        if failed { return (true, nil) }
        guard tail.count >= Self.minTailSamples else { return (false, nil) }
        return (false, enqueueLocked(tail, reason: "tail"))
    }

    private func drainTasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        let batch = tasks
        tasks.removeAll()
        return batch
    }

    private func assembleText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if failed { return nil }
        // `texts` est indexé par segment : l'ordre de la dictée est préservé quel que soit
        // l'ordre d'achèvement des tâches.
        let joined = texts.compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let deduped = TextCleanup.collapseRepetitions(joined)
        VPLog.log("streaming finish: \(texts.count) segment(s), \(deduped.count) chars")
        return deduped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Précondition : `lock` est DÉJÀ pris par l'appelant, et le reste jusqu'au retour.
    /// Renvoie la ligne de log à émettre HORS verrou (ou nil s'il n'y a rien à faire).
    private func enqueueLocked(_ segment: [Float], reason: String) -> String? {
        guard !failed else { return nil }
        let index = texts.count
        texts.append(nil)
        segmentCount += 1
        let seg = segmentCount
        let previous = chain

        let task = Task(priority: .userInitiated) { [transcriber] in
            await previous?.value

            // Court-circuit : une fois la session en échec, plus AUCUN segment ne décode.
            // Sans ça, les segments déjà en file continuaient de solliciter le moteur pour
            // un résultat que `finish()` allait de toute façon jeter.
            if self.isFailed() { return }

            // Garde anti-hallucination par segment, même logique que le batch : sous le
            // bruit de fond, Whisper invente des artefacts de training set.
            var sum: Float = 0
            for s in segment { sum += s * s }
            let rms = sqrtf(sum / Float(max(segment.count, 1)))
            if rms < 0.003 {
                VPLog.log("streaming segment #\(seg): silence (rms=\(rms)) : skipped")
                self.setText("", at: index)
                return
            }

            do {
                let t = Date()
                // Continuité : le décodeur reçoit la fin du segment précédent en prompt,
                // il garde donc casse et ponctuation quand la coupe tombe en plein mot.
                let text = try await transcriber.transcribe(samples: segment, promptText: self.promptTail())
                let cleaned = Self.isNoiseAnnotation(text) ? "" : text
                if cleaned.isEmpty && !text.isEmpty {
                    VPLog.log("streaming segment #\(seg): noise annotation \"\(String(text.prefix(40)))\" dropped")
                }
                VPLog.log(String(format: "streaming segment #%d done in %.2fs: \"%@\"",
                                 seg, Date().timeIntervalSince(t), String(cleaned.prefix(60))))
                self.setText(cleaned, at: index)
            } catch {
                VPLog.log("streaming segment #\(seg) FAILED: \(error) : batch fallback armed")
                self.markFailed()
            }
        }

        chain = task
        tasks.append(task)
        return String(format: "streaming segment #%d (%@, %.1fs) queued", seg, reason,
                      Double(segment.count) / Double(Self.sampleRate))
    }

    /// Cherche le creux d'énergie de la dernière seconde (fenêtres de 20 ms) pour couper
    /// entre deux mots plutôt qu'au milieu d'une syllabe. Renvoie l'indice de coupe, borné
    /// pour laisser au segment sa durée minimale.
    static func bestCutIndex(_ buffer: [Float]) -> Int {
        let total = buffer.count
        guard total > minSegmentSamples else { return total }
        let lookback = min(cutLookbackSamples, total - minSegmentSamples)
        guard lookback >= cutWindowSamples * 2 else { return total }
        let start = total - lookback
        var bestIndex = total
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = start
        while i + cutWindowSamples <= total {
            var sum: Float = 0
            for k in i..<(i + cutWindowSamples) { sum += buffer[k] * buffer[k] }
            let rms = sqrtf(sum / Float(cutWindowSamples))
            if rms < bestEnergy {
                bestEnergy = rms
                bestIndex = i + cutWindowSamples / 2   // milieu du creux
            }
            i += cutWindowSamples
        }
        return bestIndex
    }

    /// Sur un segment de bruit (respiration, frottement) au-dessus du seuil RMS, Whisper
    /// rend des annotations de bruit plutôt que du texte : "*cough*", "(soupir)",
    /// "[bruit]", "..." ou de la ponctuation seule. On les jette : un segment sans mot
    /// réel n'a rien à coller.
    static func isNoiseAnnotation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if let first = trimmed.first, let last = trimmed.last,
           ["*", "(", "["].contains(String(first)),
           ["*", ")", "]"].contains(String(last)) {
            return true
        }
        return !trimmed.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// Fin du texte déjà transcrit, pour le prompt du segment suivant. Appelée APRÈS
    /// `await previous?.value`, donc les segments antérieurs ont tous rendu leur texte.
    private func promptTail() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let text = texts.compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return String(text.suffix(200))
    }

    private func setText(_ text: String, at index: Int) {
        lock.lock()
        if index < texts.count { texts[index] = text }
        lock.unlock()
    }

    private func isFailed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    private func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}
