import Foundation
import AVFoundation
import Combine

final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false
    private(set) var currentURL: URL?
    let levelPublisher = PassthroughSubject<Float, Never>()
    private var levelTimer: Timer?

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxprompt-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.prepareToRecord(), rec.record() else {
            throw NSError(domain: "VoxPrompt.Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Impossible de démarrer l'enregistrement"])
        }

        recorder = rec
        currentURL = url
        isRecording = true

        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            r.updateMeters()
            let db = r.averagePower(forChannel: 0)
            let linear = max(0, min(1, (db + 50) / 50))
            self.levelPublisher.send(linear)
        }
    }

    @discardableResult
    func stop() -> URL {
        let url = currentURL ?? FileManager.default.temporaryDirectory
        recorder?.stop()
        recorder = nil
        isRecording = false
        currentURL = nil
        levelTimer?.invalidate()
        levelTimer = nil
        return url
    }

    func currentLevel() -> Float {
        guard let rec = recorder else { return -160 }
        rec.updateMeters()
        return rec.averagePower(forChannel: 0)
    }
}
