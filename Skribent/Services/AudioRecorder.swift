import AVFoundation
import Accelerate
import CoreAudio
import Combine
import Foundation
import os

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

    private var engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var micURL: URL?
    private var startedAt: Date?
    private var timer: Timer?

    private var systemCapturer: Any?  // SystemAudioCapturer; Any to avoid availability spam

    func start(_ config: Config = Config()) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        // Fresh engine per session: AVAudioEngine caches the input node's hardware
        // format from the previous session, so reusing the instance after the user
        // switches input device causes installTap to fail with a format mismatch.
        engine = AVAudioEngine()

        // Switch input device if user picked a non-default one.
        if let uid = config.inputDeviceUID, let dev = AudioDeviceManager.device(forUID: uid) {
            try setInputDevice(dev.id)
            Log.recorder.info("using input device: \(dev.name, privacy: .public)")
        } else if let dflt = AudioDeviceManager.defaultInput() {
            Log.recorder.info("using system default input: \(dflt.name, privacy: .public)")
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
                    Log.recorder.error("system audio start failed: \(error.localizedDescription, privacy: .public)")
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
            Log.recorder.info("mixed mic(\(micSamples.count, privacy: .public)) + sys(\(sysSamples.count, privacy: .public)) → \(mixed.count, privacy: .public) samples @ 16k")
            try? FileManager.default.removeItem(at: mic)
            try? FileManager.default.removeItem(at: sysURL)
            return mixedURL
        } catch {
            Log.recorder.error("mix failed: \(error.localizedDescription, privacy: .public). Falling back to mic-only.")
            return mic
        }
    }

    private func mix(a: [Float], b: [Float]) -> [Float] {
        // vDSP_vadd over the overlapping prefix, then vDSP_vclip — ~50× faster than the
        // scalar version with branches on long recordings.
        let n = Swift.max(a.count, b.count)
        let overlap = Swift.min(a.count, b.count)
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            // Sum the overlap.
            a.withUnsafeBufferPointer { aBuf in
                b.withUnsafeBufferPointer { bBuf in
                    if let aBase = aBuf.baseAddress, let bBase = bBuf.baseAddress, overlap > 0 {
                        vDSP_vadd(aBase, 1, bBase, 1, dstBase, 1, vDSP_Length(overlap))
                    }
                }
            }
            // Copy the tail of the longer array.
            if a.count > overlap {
                a.withUnsafeBufferPointer { aBuf in
                    if let aBase = aBuf.baseAddress {
                        let tail = a.count - overlap
                        memcpy(dstBase.advanced(by: overlap), aBase.advanced(by: overlap), tail * MemoryLayout<Float>.size)
                    }
                }
            } else if b.count > overlap {
                b.withUnsafeBufferPointer { bBuf in
                    if let bBase = bBuf.baseAddress {
                        let tail = b.count - overlap
                        memcpy(dstBase.advanced(by: overlap), bBase.advanced(by: overlap), tail * MemoryLayout<Float>.size)
                    }
                }
            }
            // Soft-clip to [-1, 1].
            var lo: Float = -1, hi: Float = 1
            vDSP_vclip(dstBase, 1, &lo, &hi, dstBase, 1, vDSP_Length(n))
        }
        return out
    }

    /// Throttle for the audio render-thread → MainActor hop. The throttle itself is thread-safe
    /// (NSLock inside); marking the property `nonisolated` lets the audio callback probe it
    /// without crossing the MainActor.
    nonisolated private let levelThrottle = LevelPublishThrottle(intervalSec: 0.05)

    nonisolated private func publishLevel(_ buffer: AVAudioPCMBuffer) {
        guard let chan = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sumSq: Float = 0
        vDSP_svesq(chan, 1, &sumSq, vDSP_Length(n))
        let rms = sqrt(sumSq / Float(n))
        let normalized = Swift.min(1, Swift.max(0, rms * 4))
        guard levelThrottle.shouldPublishNow() else { return }
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

/// Thread-safe throttle gate. Callable from any thread (including audio render thread).
/// Backed by `OSAllocatedUnfairLock` so the type is `Sendable` without an `@unchecked` escape.
final class LevelPublishThrottle: Sendable {
    private let intervalSec: TimeInterval
    private let lastAt = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    init(intervalSec: TimeInterval) { self.intervalSec = intervalSec }

    func shouldPublishNow() -> Bool {
        lastAt.withLock { last in
            let now = CFAbsoluteTimeGetCurrent()
            if now - last < intervalSec { return false }
            last = now
            return true
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
