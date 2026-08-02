import Foundation

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

    // État protégé par `lock` — `ingest` arrive sur le thread temps réel du tap audio,
    // les résultats de transcription sur des Tasks concurrents.
    private var pending: [Float] = []      // samples du segment en cours (pas encore transcrits)
    private var silentRun = 0              // samples consécutifs sous le seuil de silence
    private var texts: [String?] = []      // résultats ordonnés par segment (nil = en cours)
    private var chain: Task<Void, Never>?  // sérialise les transcriptions, préserve l'ordre
    private var failed = false
    private var finished = false
    private var segmentCount = 0

    // Découpage : une pause de 250 ms coupe un segment d'au moins 2,5 s ; au-delà de 12 s
    // de parole ininterrompue on coupe quand même (borne la latence du dernier segment et
    // la mémoire). Le seuil RMS est aligné sur le garde anti-hallucination du batch (0.003),
    // légèrement relevé car une pause entre deux phrases n'est jamais un silence parfait.
    private static let sampleRate = 16_000
    private static let silenceThreshold: Float = 0.004
    private static let minSilenceSamples = sampleRate / 4        // 250 ms
    private static let minSegmentSamples = sampleRate * 5 / 2    // 2,5 s
    private static let maxSegmentSamples = sampleRate * 12       // 12 s
    private static let minTailSamples = sampleRate / 4           // tail < 250 ms : rien à dire

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
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
        let forcedCut = pending.count >= Self.maxSegmentSamples
        guard naturalCut || forcedCut else { lock.unlock(); return }

        let segment = pending
        pending = []
        silentRun = 0
        lock.unlock()

        enqueue(segment, reason: forcedCut && !naturalCut ? "forced" : "pause")
    }

    /// Fin de dictée : transcrit la queue restante, attend les segments en vol et renvoie
    /// le texte complet. nil = un segment a échoué, l'appelant doit retomber sur le batch.
    func finish() async -> String? {
        lock.lock()
        finished = true
        let tail = pending
        pending = []
        let alreadyFailed = failed
        lock.unlock()

        if alreadyFailed { return nil }
        if tail.count >= Self.minTailSamples {
            enqueue(tail, reason: "tail")
        }

        await chain?.value

        lock.lock()
        defer { lock.unlock() }
        if failed { return nil }
        let joined = texts.compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let deduped = Transcriber.collapseRepetitions(joined)
        VPLog.log("streaming finish: \(texts.count) segment(s), \(deduped.count) chars")
        return deduped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enqueue(_ segment: [Float], reason: String) {
        lock.lock()
        let index = texts.count
        texts.append(nil)
        segmentCount += 1
        let seg = segmentCount
        let previous = chain
        lock.unlock()

        VPLog.log(String(format: "streaming segment #%d (%@, %.1fs) queued", seg, reason,
                         Double(segment.count) / Double(Self.sampleRate)))

        let task = Task(priority: .userInitiated) { [transcriber] in
            await previous?.value

            // Garde anti-hallucination par segment, même logique que le batch : sous le
            // bruit de fond, Whisper invente des artefacts de training set.
            var sum: Float = 0
            for s in segment { sum += s * s }
            let rms = sqrtf(sum / Float(max(segment.count, 1)))
            if rms < 0.003 {
                VPLog.log("streaming segment #\(seg): silence (rms=\(rms)) — skipped")
                self.setText("", at: index)
                return
            }

            do {
                let t = Date()
                let text = try await transcriber.transcribe(samples: segment)
                let cleaned = Self.isNoiseAnnotation(text) ? "" : text
                if cleaned.isEmpty && !text.isEmpty {
                    VPLog.log("streaming segment #\(seg): noise annotation \"\(String(text.prefix(40)))\" dropped")
                }
                VPLog.log(String(format: "streaming segment #%d done in %.2fs: \"%@\"",
                                 seg, Date().timeIntervalSince(t), String(cleaned.prefix(60))))
                self.setText(cleaned, at: index)
            } catch {
                VPLog.log("streaming segment #\(seg) FAILED: \(error) — batch fallback armed")
                self.markFailed()
            }
        }

        lock.lock()
        chain = task
        lock.unlock()
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

    private func setText(_ text: String, at index: Int) {
        lock.lock()
        if index < texts.count { texts[index] = text }
        lock.unlock()
    }

    private func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}
