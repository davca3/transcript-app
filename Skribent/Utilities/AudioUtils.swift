import AVFoundation
import Accelerate

enum AudioUtils {
    static let targetSampleRate: Double = 16_000

    /// Decode any AVFoundation-readable file into 16 kHz mono Float32 PCM samples.
    static func loadAndResample(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw AudioError.formatUnavailable }

        let frameCapacity = AVAudioFrameCount(file.length)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCapacity) else {
            throw AudioError.bufferAllocFailed
        }
        try file.read(into: inBuffer)

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioError.formatUnavailable
        }

        // Estimate output capacity (resample ratio + small slack)
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioError.bufferAllocFailed
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error || error != nil {
            throw AudioError.conversionFailed(error?.localizedDescription ?? "unknown")
        }

        guard let channelData = outBuffer.floatChannelData?[0] else { return [] }
        let count = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: count))
    }

    /// Write Float32 mono samples at 16 kHz as a WAV file (Core Audio fmt = LinearPCM).
    static func writeWav(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw AudioError.formatUnavailable }

        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioError.bufferAllocFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Slice mono samples by time range (in seconds, 16 kHz).
    static func slice(_ samples: [Float], from start: TimeInterval, to end: TimeInterval) -> [Float] {
        let sr = targetSampleRate
        let lo = max(0, Int(start * sr))
        let hi = min(samples.count, Int(end * sr))
        guard lo < hi else { return [] }
        return Array(samples[lo..<hi])
    }

    /// Energy-based VAD with adaptive threshold. Returns (start, end) in seconds for each
    /// speech region in the original timeline. Padding + min-duration prevent over-trimming.
    static func detectSpeech(
        samples: [Float],
        windowSec: Double = 0.05,
        minSpeechSec: Double = 0.4,
        minSilenceSec: Double = 0.6,
        paddingSec: Double = 0.2
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let sr = targetSampleRate
        let windowSamples = max(1, Int(windowSec * sr))
        guard samples.count >= windowSamples else { return [] }

        // Per-window RMS
        var rms: [Float] = []
        rms.reserveCapacity(samples.count / windowSamples + 1)
        var i = 0
        while i + windowSamples <= samples.count {
            var sumSq: Float = 0
            for j in 0..<windowSamples { let v = samples[i + j]; sumSq += v * v }
            rms.append(Foundation.sqrt(sumSq / Float(windowSamples)))
            i += windowSamples
        }
        guard !rms.isEmpty else { return [] }

        // Adaptive threshold: 3× noise-floor (10th percentile), with hard floor.
        let sorted = rms.sorted()
        let noiseFloor = sorted[max(0, sorted.count / 10)]
        let threshold = max(noiseFloor * 3, 0.003)

        let minSpeechWindows = max(1, Int(minSpeechSec / windowSec))
        let minSilenceWindows = max(1, Int(minSilenceSec / windowSec))
        let padWindows = max(0, Int(paddingSec / windowSec))

        // Walk windows, building speech regions, closing them on silence ≥ minSilenceWindows.
        var regions: [(start: Int, end: Int)] = []
        var openStart: Int?
        var lastSpeech: Int?
        for (w, energy) in rms.enumerated() {
            if energy > threshold {
                if openStart == nil { openStart = w }
                lastSpeech = w
            } else if let last = lastSpeech, w - last >= minSilenceWindows,
                      let s = openStart {
                if last - s + 1 >= minSpeechWindows { regions.append((s, last)) }
                openStart = nil; lastSpeech = nil
            }
        }
        if let s = openStart, let last = lastSpeech, last - s + 1 >= minSpeechWindows {
            regions.append((s, last))
        }

        // Pad + merge adjacent regions that overlap after padding.
        let totalW = rms.count
        var padded: [(start: Int, end: Int)] = []
        for r in regions {
            let s = max(0, r.start - padWindows)
            let e = min(totalW - 1, r.end + padWindows)
            if !padded.isEmpty, s <= padded[padded.count - 1].end + 1 {
                padded[padded.count - 1].end = e
            } else {
                padded.append((s, e))
            }
        }

        return padded.map { (
            start: TimeInterval($0.start) * windowSec,
            end: TimeInterval($0.end + 1) * windowSec
        ) }
    }

    /// Trim silence per `detectSpeech`. Returns concatenated speech-only samples and a closure
    /// that translates a time offset in the trimmed timeline back to the original timeline.
    static func trimSilence(samples: [Float]) -> (trimmed: [Float], translate: (TimeInterval) -> TimeInterval) {
        let regions = detectSpeech(samples: samples)
        guard !regions.isEmpty else { return (samples, { $0 }) }

        var trimmed: [Float] = []
        trimmed.reserveCapacity(samples.count)
        var offsets: [(trimStart: TimeInterval, origStart: TimeInterval)] = []
        for r in regions {
            let trimStart = TimeInterval(trimmed.count) / targetSampleRate
            let lo = max(0, Int(r.start * targetSampleRate))
            let hi = min(samples.count, Int(r.end * targetSampleRate))
            guard lo < hi else { continue }
            trimmed.append(contentsOf: samples[lo..<hi])
            offsets.append((trimStart, r.start))
        }

        let translate: (TimeInterval) -> TimeInterval = { t in
            var result = t
            for entry in offsets {
                if t >= entry.trimStart {
                    result = entry.origStart + (t - entry.trimStart)
                } else {
                    break
                }
            }
            return result
        }
        return (trimmed, translate)
    }
}

enum AudioError: LocalizedError {
    case formatUnavailable
    case bufferAllocFailed
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .formatUnavailable: return "Nepodařilo se vytvořit audio formát."
        case .bufferAllocFailed: return "Nepodařilo se alokovat audio buffer."
        case .conversionFailed(let msg): return "Konverze audia selhala: \(msg)"
        }
    }
}
