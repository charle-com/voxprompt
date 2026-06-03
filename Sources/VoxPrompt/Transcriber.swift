import Foundation
import AVFoundation
import WhisperKit

actor Transcriber {
    private var pipeline: WhisperKit?
    private var loading: Task<WhisperKit, Error>?

    private func ensurePipeline() async throws -> WhisperKit {
        if let p = pipeline { return p }
        if let existing = loading { return try await existing.value }
        let task = Task { () throws -> WhisperKit in
            VPLog.log("pipeline init start, model=\(Settings.shared.modelIdentifier)")
            let config = WhisperKitConfig(model: Settings.shared.modelIdentifier)
            let kit = try await WhisperKit(config)
            VPLog.log("pipeline init done")
            return kit
        }
        loading = task
        let p = try await task.value
        pipeline = p
        loading = nil
        return p
    }

    func warmup() async {
        do { _ = try await ensurePipeline() }
        catch { VPLog.log("warmup error: \(error)") }
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
        VPLog.log(String(format: "pipeline ready in %.2fs", Date().timeIntervalSince(t0)))

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
        VPLog.log("calling pipe.transcribe (detached) lang=\(language ?? "auto")")
        let t1 = Date()

        // Défense en profondeur contre les boucles de répétition du décodeur Turbo, qui
        // sont réapparues sur macOS 26.5.1 malgré la recette WhisperKit ci-dessus. Trois
        // filets indépendants, du plus précis au plus brutal :
        //   1. Détection de boucle DANS le callback : dès qu'un n-gramme se répète
        //      anormalement pendant le décodage, on renvoie `false` pour couper Whisper
        //      à la source en quelques centaines de ms, sans attendre la fin.
        //   2. Watchdog timeout : si le décodeur se fige AVANT d'émettre un callback
        //      exploitable, on rend la main au bout d'un délai borné (proportionnel à la
        //      durée audio) plutôt que de laisser le HUD tourner à l'infini.
        //   3. collapseRepetitions sur le texte final, pour nettoyer tout résidu de
        //      répétition ayant survécu aux deux premiers filets.
        let timeoutSeconds = max(20.0, audioSeconds * 5.0)

        let transcribeTask = Task.detached(priority: .userInitiated) { () async throws -> [TranscriptionResult] in
            try await pipe.transcribe(audioArray: samples, decodeOptions: options, callback: { progress in
                if Task.isCancelled { return false }               // coupé par le watchdog
                if Self.isRepetitionLoop(progress.text) {
                    VPLog.log("repetition loop detected mid-decode — aborting")
                    return false                                    // filet 1 : coupe à la source
                }
                VPLog.log("progress: \(progress.text.suffix(80))")
                return nil
            })
        }

        let results: [TranscriptionResult]
        do {
            results = try await withThrowingTaskGroup(of: [TranscriptionResult].self) { group in
                group.addTask { try await transcribeTask.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw TranscriberError.timeout(seconds: timeoutSeconds)
                }
                guard let first = try await group.next() else { return [] }
                group.cancelAll()
                return first
            }
        } catch {
            transcribeTask.cancel()                                 // filet 2 : libère le décodeur
            VPLog.log("transcribe aborted: \(error)")
            throw error
        }

        VPLog.log(String(format: "whisper done in %.2fs segments=%d", Date().timeIntervalSince(t1), results.count))
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

    private static func buildGlossaryTokens(pipe: WhisperKit, language: String?) async -> [Int]? {
        let raw = Settings.shared.glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let items = raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
        // Phrase de contexte naturelle : Whisper doit croire à une transcription précédente
        // qui "ouvre" sur du nouveau texte. Un prompt trop court ou trop étrange le fait
        // émettre EOT immédiatement → résultat vide.
        let joined = items.joined(separator: ", ")
        let prompt: String
        if language == "fr" {
            prompt = " Voici la suite de la conversation. On y parle notamment de \(joined). "
        } else {
            prompt = " This is the continuation. It mentions \(joined). "
        }
        let tokens = tokenizer.encode(text: prompt)
        VPLog.log("glossary prompt (\(items.count) items) → \(tokens.count) tokens: \"\(prompt.prefix(90))\"")
        return tokens
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
