import Foundation
import CoreML
import WhisperKit

// Banc de mesure du cout de transcription en fonction de la taille des segments.
// Usage : voxbench <fichier.wav 16kHz mono> [profil]

func loadFloats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    // WAV PCM 16 bits : on saute l'entete de 44 octets (afconvert canonique).
    let header = 44
    let count = (data.count - header) / 2
    var out = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
        let base = raw.baseAddress!.advanced(by: header).assumingMemoryBound(to: Int16.self)
        for i in 0..<count { out[i] = Float(Int16(littleEndian: base[i])) / 32768.0 }
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: voxbench file.wav [profile]"); exit(1) }
let wav = URL(fileURLWithPath: args[1])
let profileID = args.count >= 3 ? args[2] : "cpu-only"

let model = "openai_whisper-large-v3-v20240930_turbo_632MB"
let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
    .appendingPathComponent(model)

let compute: ModelComputeOptions = {
    switch profileID {
    case "ane-encoder":
        return ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                                   textDecoderCompute: .cpuOnly, prefillCompute: .cpuOnly)
    case "gpu-encoder":
        return ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndGPU,
                                   textDecoderCompute: .cpuOnly, prefillCompute: .cpuOnly)
    case "ane-full":
        return ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                                   textDecoderCompute: .cpuAndNeuralEngine, prefillCompute: .cpuAndNeuralEngine)
    default:
        return ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly,
                                   textDecoderCompute: .cpuOnly, prefillCompute: .cpuOnly)
    }
}()

let samples = try loadFloats(wav)
let rate = 16_000.0
print("audio: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / rate))s), profil=\(profileID)")

let t0 = Date()
let kit = try await WhisperKit(WhisperKitConfig(model: model, modelFolder: folder.path,
                                                computeOptions: compute, download: false))
print(String(format: "pipeline chargé en %.2fs", Date().timeIntervalSince(t0)))

func options() -> DecodingOptions {
    DecodingOptions(
        verbose: false, task: .transcribe, language: "fr", temperature: 0.0,
        temperatureFallbackCount: 3, usePrefillPrompt: true, usePrefillCache: true,
        skipSpecialTokens: true, withoutTimestamps: true,
        compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6,
        chunkingStrategy: .vad
    )
}

// Warmup : absorbe la compilation CoreML pour ne pas la compter dans la 1re mesure.
let warm = Array(samples.prefix(16_000 * 2))
_ = try? await kit.transcribe(audioArray: warm, decodeOptions: options())
print("warmup ok\n")

struct Row { let window: Int; let segs: Int; let costs: [Double]; let total: Double; let tail: Double }
var rows: [Row] = []

let windows = [32, 25, 15, 10, 5]
for w in windows {
    let size = Int(rate) * w
    var chunks: [[Float]] = []
    var i = 0
    while i < samples.count {
        let end = min(i + size, samples.count)
        chunks.append(Array(samples[i..<end]))
        i = end
    }
    var costs: [Double] = []
    var text = ""
    for c in chunks {
        let t = Date()
        let r = try await kit.transcribe(audioArray: c, decodeOptions: options())
        costs.append(Date().timeIntervalSince(t))
        text += r.map(\.text).joined(separator: " ") + " "
    }
    // Simulation temps reel : le segment k est disponible a (k+1)*w secondes de dictee
    // (le dernier a la fin exacte de l'audio). Traitement en serie par un seul worker.
    let audioSec = Double(samples.count) / rate
    var free = 0.0
    for (k, cost) in costs.enumerated() {
        let availableAt = min(Double((k + 1) * w), audioSec)
        free = max(free, availableAt) + cost
    }
    let tail = free - audioSec
    rows.append(Row(window: w, segs: chunks.count, costs: costs, total: costs.reduce(0, +), tail: tail))
    print(String(format: "fenêtre %2ds → %d segment(s), calcul total %.2fs, latence après relâchement %.2fs",
                 w, chunks.count, costs.reduce(0, +), tail))
    print("   coûts: " + costs.map { String(format: "%.2f", $0) }.joined(separator: " "))
    print("   texte: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))\n")
}

print("=== récap (audio \(String(format: "%.1f", Double(samples.count) / rate))s, \(profileID)) ===")
for r in rows {
    print(String(format: "  %2ds : %d seg | calcul %5.2fs | RTF %.2f | latence relâchement %5.2fs",
                 r.window, r.segs, r.total, r.total / (Double(samples.count) / rate), r.tail))
}
