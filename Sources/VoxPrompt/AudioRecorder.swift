import Foundation
import AVFoundation
import AudioToolbox
import Combine

final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private(set) var isRecording = false
    private(set) var isWarm = false
    private(set) var currentURL: URL?
    private(set) var lastDeviceName: String = "unknown"
    private(set) var lastRMS: Float = 0
    let levelPublisher = PassthroughSubject<Float, Never>()

    /// Force CoreAudio HAL + AVAudioEngine input unit to fully initialize. At boot, the
    /// HAL daemon takes a moment to settle and the very first `engine.start()` can fail
    /// with an opaque OSStatus, leaving the engine in a broken state until the app is
    /// relaunched. Calling this once at launch (off the main thread) eliminates that
    /// window: the first user-facing `start()` runs against an already-armed unit.
    func warmup() {
        guard !isWarm, !isRecording else { return }
        do {
            try pinDeviceIfRequested()
            let inFormat = engine.inputNode.inputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
                VPLog.log("warmup: skipped, input format invalid (\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch)")
                return
            }
            engine.prepare()
            try engine.start()
            engine.stop()
            isWarm = true
            VPLog.log("audio warmup OK device=\(lastDeviceName) inputFormat=\(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch")
        } catch {
            VPLog.log("audio warmup failed: \(error.localizedDescription) — first start() will retry")
            rebuildEngine()
        }
    }

    func start() throws {
        guard !isRecording else { return }
        do {
            try startInternal()
        } catch {
            VPLog.log("start failed once: \(error.localizedDescription) — rebuilding engine and retrying")
            rebuildEngine()
            Thread.sleep(forTimeInterval: 0.25)
            try startInternal()
        }
    }

    private func startInternal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxprompt-\(UUID().uuidString).wav")

        try pinDeviceIfRequested()

        let inFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "VoxPrompt.Recorder", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Format d'entree invalide (\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch) sur device \(lastDeviceName)"])
        }
        inputFormat = inFormat

        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: fileSettings)
        file = outFile

        let processingFormat = outFile.processingFormat
        guard let conv = AVAudioConverter(from: inFormat, to: processingFormat) else {
            throw NSError(domain: "VoxPrompt.Recorder", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Converter audio impossible (\(inFormat) -> \(processingFormat))"])
        }
        converter = conv

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        isWarm = true
        currentURL = url
        VPLog.log("rec start device=\(lastDeviceName) inputFormat=\(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch")
    }

    private func pinDeviceIfRequested() throws {
        if let uid = Settings.shared.preferredInputUID {
            do {
                lastDeviceName = try setEngineInputDevice(uid: uid)
            } catch {
                VPLog.log("warn: pin device uid=\(uid) failed (\(error.localizedDescription)), falling back to system default")
                lastDeviceName = Self.currentDefaultDeviceName() ?? "default"
            }
        } else {
            lastDeviceName = Self.currentDefaultDeviceName() ?? "default"
        }
    }

    private func rebuildEngine() {
        // AVAudioEngine cannot be restarted reliably once start() has thrown; the input
        // unit ends up in an undefined state. Replacing the whole engine is the only
        // documented path to recover, per Apple Audio forum threads on cold start failures.
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = AVAudioEngine()
        file = nil
        converter = nil
        inputFormat = nil
        isRecording = false
        isWarm = false
        currentURL = nil
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let file, let inputFormat else { return }
        let outFormat = file.processingFormat
        let ratio = outFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var supplied = false
        // .noDataNow (not .endOfStream) — endOfStream puts the converter in a terminal state
        // and silently drops every subsequent tap callback, capping the wav at one buffer.
        let status = converter.convert(to: outBuf, error: &error) { _, ioStatus in
            if supplied { ioStatus.pointee = .noDataNow; return nil }
            supplied = true
            ioStatus.pointee = .haveData
            return buffer
        }
        if status == .error || outBuf.frameLength == 0 { return }

        do { try file.write(from: outBuf) } catch {
            VPLog.log("write error: \(error)")
            return
        }

        if let ch = outBuf.floatChannelData?[0] {
            let n = Int(outBuf.frameLength)
            var sum: Float = 0
            for i in 0..<n { let s = ch[i]; sum += s * s }
            let rms = sqrtf(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 1e-6))
            let linear = max(0, min(1, (db + 50) / 50))
            DispatchQueue.main.async { [weak self] in
                self?.levelPublisher.send(linear)
            }
        }
    }

    @discardableResult
    func stop() -> URL {
        let url = currentURL ?? FileManager.default.temporaryDirectory
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        file = nil
        converter = nil
        inputFormat = nil
        isRecording = false
        currentURL = nil
        lastRMS = Self.fileRMS(at: url)
        VPLog.log(String(format: "rec stop file=%@ rms=%.4f device=%@", url.lastPathComponent, lastRMS, lastDeviceName))
        return url
    }

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

    // MARK: CoreAudio device selection

    private func setEngineInputDevice(uid: String) throws -> String {
        let devices = try Self.listDeviceIDs()
        var foundID: AudioDeviceID = 0
        var foundName = "unknown"
        for d in devices {
            if Self.stringProperty(device: d, selector: kAudioDevicePropertyDeviceUID) == uid {
                foundID = d
                foundName = Self.stringProperty(device: d, selector: kAudioObjectPropertyName) ?? "device"
                break
            }
        }
        guard foundID != 0 else {
            throw NSError(domain: "VoxPrompt.Recorder", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "Device UID \(uid) not present"])
        }
        guard let unit = engine.inputNode.audioUnit else {
            throw NSError(domain: "VoxPrompt.Recorder", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "No audioUnit on inputNode"])
        }
        var dev = foundID
        let setStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard setStatus == noErr else {
            throw NSError(domain: "VoxPrompt.Recorder", code: Int(setStatus),
                          userInfo: [NSLocalizedDescriptionKey: "AudioUnitSetProperty CurrentDevice failed (\(setStatus))"])
        }
        return foundName
    }

    private static func currentDefaultDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID)
        guard status == noErr else { return nil }
        return stringProperty(device: deviceID, selector: kAudioObjectPropertyName)
    }

    private static func listDeviceIDs() throws -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size)
        guard status == noErr else { throw NSError(domain: "VoxPrompt.Recorder", code: Int(status)) }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw NSError(domain: "VoxPrompt.Recorder", code: Int(status)) }
        return ids
    }

    private static func stringProperty(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
