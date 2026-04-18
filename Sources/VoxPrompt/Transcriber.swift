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

    func transcribe(fileURL: URL) async throws -> String {
        let t0 = Date()
        VPLog.log("transcribe start file=\(fileURL.lastPathComponent)")
        let pipe = try await ensurePipeline()
        VPLog.log(String(format: "pipeline ready in %.2fs", Date().timeIntervalSince(t0)))

        let samples = try Self.loadFloatSamples(from: fileURL)
        VPLog.log("audio loaded samples=\(samples.count) (\(samples.count / 16000)s)")

        let language = Settings.shared.language
        let options = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
        VPLog.log("calling pipe.transcribe (detached) lang=\(language ?? "auto")")
        let t1 = Date()
        let results: [TranscriptionResult] = try await Task.detached(priority: .userInitiated) {
            try await pipe.transcribe(audioArray: samples, decodeOptions: options, callback: { progress in
                VPLog.log("progress: \(progress.text.prefix(80))")
                return nil
            })
        }.value
        VPLog.log(String(format: "whisper done in %.2fs segments=%d", Date().timeIntervalSince(t1), results.count))
        let raw = results.map(\.text).joined(separator: " ")
        let corrected = Self.applyGlossary(raw)
        if corrected != raw {
            VPLog.log("glossary applied: \"\(raw.prefix(60))\" → \"\(corrected.prefix(60))\"")
        }
        return corrected
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
