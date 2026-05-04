import AVFoundation
import CoreAudio
import Combine
import Foundation

@MainActor
final class AudioRecorder: ObservableObject {
    struct Config {
        var inputDeviceUID: String?     // nil = system default
        var captureSystemAudio: Bool = false
    }

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var isFinalizing = false  // true while mixing after stop

    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var micURL: URL?
    private var startedAt: Date?
    private var timer: Timer?

    private var systemCapturer: Any?  // SystemAudioCapturer; Any to avoid availability spam

    func start(_ config: Config = Config()) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        // Switch input device if user picked a non-default one.
        if let uid = config.inputDeviceUID, let dev = AudioDeviceManager.device(forUID: uid) {
            try setInputDevice(dev.id)
            print("[Recorder] using input device: \(dev.name)")
        } else if let dflt = AudioDeviceManager.defaultInput() {
            print("[Recorder] using system default input: \(dflt.name)")
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let micURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skribent-mic-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let f = try AVAudioFile(forWriting: micURL, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        self.micFile = f
        self.micURL = micURL

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.micFile?.write(from: buffer)
            self.publishLevel(buffer)
        }

        engine.prepare()
        try engine.start()

        // System audio (optional). Async start; we accept the small race because
        // ScreenCaptureKit usually starts within ~100 ms — good enough for meetings.
        if config.captureSystemAudio, #available(macOS 13.0, *) {
            let cap = SystemAudioCapturer()
            self.systemCapturer = cap
            Task { [weak self] in
                do {
                    try await cap.start()
                } catch {
                    await MainActor.run { self?.systemCapturer = nil }
                    print("[Recorder] system audio start failed: \(error)")
                }
            }
        }

        isRecording = true
        startedAt = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
    }

    /// Stop recording, optionally mix mic + system audio, return URL of the resulting file.
    func stopAndFinalize() async -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micFile = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        level = 0

        let mic = micURL
        var sysURL: URL?
        if #available(macOS 13.0, *), let cap = systemCapturer as? SystemAudioCapturer {
            sysURL = await cap.stop()
        }
        systemCapturer = nil
        micURL = nil

        guard let mic else { return nil }
        guard let sysURL else { return mic }  // mic-only recording

        // Mix mic + system audio: resample both to 16k mono and sum into a WAV file.
        isFinalizing = true
        defer { isFinalizing = false }
        let mixedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skribent-mix-\(UUID().uuidString).wav")
        do {
            let micSamples = try AudioUtils.loadAndResample(from: mic)
            let sysSamples = try AudioUtils.loadAndResample(from: sysURL)
            let mixed = mix(a: micSamples, b: sysSamples)
            try AudioUtils.writeWav(samples: mixed, to: mixedURL)
            print("[Recorder] mixed mic(\(micSamples.count)) + sys(\(sysSamples.count)) → \(mixed.count) samples @ 16k")
            try? FileManager.default.removeItem(at: mic)
            try? FileManager.default.removeItem(at: sysURL)
            return mixedURL
        } catch {
            print("[Recorder] mix failed: \(error). Falling back to mic-only.")
            return mic
        }
    }

    private func mix(a: [Float], b: [Float]) -> [Float] {
        let n = max(a.count, b.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            // Sum with soft clip to avoid >1.0 peaks.
            let s = av + bv
            out[i] = max(-1, min(1, s))
        }
        return out
    }

    nonisolated private func publishLevel(_ buffer: AVAudioPCMBuffer) {
        guard let chan = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sumSq: Float = 0
        for i in 0..<n { let v = chan[i]; sumSq += v * v }
        let rms = sqrt(sumSq / Float(max(n, 1)))
        let normalized = min(1, max(0, rms * 4))
        Task { @MainActor [weak self] in self?.level = normalized }
    }

    /// Set the input device on the engine's input AudioUnit. Must be called before `engine.start()`.
    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let au = engine.inputNode.audioUnit else {
            throw RecorderError.deviceSwitchFailed("inputNode.audioUnit is nil")
        }
        var devID = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw RecorderError.deviceSwitchFailed("AudioUnitSetProperty status=\(status)")
        }
    }
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case deviceSwitchFailed(String)
    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Nahrávání už běží."
        case .deviceSwitchFailed(let msg): return "Nepodařilo se přepnout vstup: \(msg)"
        }
    }
}
