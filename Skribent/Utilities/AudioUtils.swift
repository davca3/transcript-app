import AVFoundation
import Accelerate

enum AudioUtils {
    static let targetSampleRate: Double = 16_000

    /// Sample rate used for the on-disk enhanced audio (DeepFilterNet3 native rate; preserves
    /// playback fidelity). The pipeline still downsamples this to `targetSampleRate` for
    /// Whisper + diarize.
    static let storedSampleRate: Double = 48_000

    /// Decode any AVFoundation-readable file into 16 kHz mono Float32 PCM samples.
    /// Convenience wrapper around `loadAndResample(from:sampleRate:)` for callers that want
    /// pipeline-rate audio directly (Whisper + diarize input).
    static func loadAndResample(from url: URL) throws -> [Float] {
        try loadAndResample(from: url, sampleRate: targetSampleRate)
    }

    /// Decode any AVFoundation-readable file into mono Float32 PCM samples at the requested
    /// sample rate. Streams in chunks instead of loading the whole file → working set stays
    /// bounded (peak ~1 MB of buffers + the result array, vs. previously holding the full
    /// source + full output + return copy = ~1.8 GB for a 1h 48k stereo file).
    static func loadAndResample(from url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw AudioError.formatUnavailable }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioError.formatUnavailable
        }

        // ~2s of input at typical sample rates — enough to amortize converter call overhead,
        // small enough to keep memory low.
        let inChunkFrames: AVAudioFrameCount = 96_000
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outChunkFrames = AVAudioFrameCount(Double(inChunkFrames) * ratio + 1024)

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inChunkFrames),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outChunkFrames)
        else { throw AudioError.bufferAllocFailed }

        let estimatedTotal = Int(Double(file.length) * ratio + 1024)
        var result = [Float](); result.reserveCapacity(estimatedTotal)

        var fileExhausted = false
        var error: NSError?

        while true {
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if fileExhausted {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: inChunkFrames)
                } catch {
                    fileExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    fileExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error {
                throw AudioError.conversionFailed(error?.localizedDescription ?? "unknown")
            }
            if let chan = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                let count = Int(outBuffer.frameLength)
                result.append(contentsOf: UnsafeBufferPointer(start: chan, count: count))
            }
            if status == .endOfStream { break }
            if status == .inputRanDry, fileExhausted { break }
        }
        return result
    }

    /// Write Float32 mono samples as a WAV file at the given sample rate (default 16 kHz for
    /// backwards compat). Core Audio fmt = LinearPCM, 32-bit float, mono, non-interleaved.
    static func writeWav(samples: [Float], to url: URL, sampleRate: Double = targetSampleRate) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw AudioError.formatUnavailable }

        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
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

    /// In-memory resample of mono Float32 samples between two sample rates via AVAudioConverter.
    /// Used to bridge the on-disk 48 kHz stored audio with the 16 kHz pipeline input.
    static func resample(samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        if inputRate == outputRate { return samples }
        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        ),
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false
        ),
        let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw AudioError.formatUnavailable }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioError.bufferAllocFailed
        }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let ratio = outputRate / inputRate
        let outCapacity = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioError.bufferAllocFailed
        }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error {
            throw AudioError.conversionFailed(error?.localizedDescription ?? "unknown")
        }

        let count = Int(outBuffer.frameLength)
        guard let chan = outBuffer.floatChannelData?[0], count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: chan, count: count))
    }

    /// RMS-loudness normalize + soft peak limit. Brings quiet speech up to a consistent
    /// listening level without clipping. `targetRMSdBFS` of −20 dBFS is a safe broadcast-style
    /// target for speech; `peakCeilingDBFS` of −1 dBFS leaves headroom for downstream codecs.
    /// Mutates in place via Accelerate vDSP — avoids extra array allocations on long audio.
    static func loudnessNormalize(
        samples: inout [Float],
        targetRMSdBFS: Float = -20,
        peakCeilingDBFS: Float = -1
    ) {
        guard !samples.isEmpty else { return }
        let n = vDSP_Length(samples.count)

        // Current RMS (vDSP_rmsqv handles the sum-of-squares + sqrt in a single pass).
        var rms: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, n)
        }
        guard rms > 1e-6 else { return }   // basically silence — leave it alone

        let targetRMS = pow(10.0, targetRMSdBFS / 20)   // dBFS → linear
        let peakCeiling = pow(10.0, peakCeilingDBFS / 20)
        var gain: Float = targetRMS / rms

        // Don't let the gain push peak above the ceiling — preserves transients without limiter.
        var peakAfter: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_maxmgv(ptr.baseAddress!, 1, &peakAfter, n)
        }
        peakAfter *= gain
        if peakAfter > peakCeiling {
            gain *= peakCeiling / peakAfter
        }
        // Cap absolute gain to avoid blowing up extremely quiet inputs (would amplify residual noise).
        gain = min(gain, 32)

        samples.withUnsafeMutableBufferPointer { ptr in
            vDSP_vsmul(ptr.baseAddress!, 1, &gain, ptr.baseAddress!, 1, n)
        }
    }

    /// Single-pole IIR high-pass filter. Removes low-frequency rumble (HVAC hum, mic
    /// handling, table thuds) — that "noise floor" component of recordings is the most
    /// audibly intrusive part and confuses Whisper less when it's gone.
    /// Default cutoff 80 Hz: under fundamental of speech (~85 Hz male, ~165 Hz female), so
    /// voice quality is preserved.
    static func applyHighPassFilter(samples: inout [Float], cutoffHz: Float, sampleRate: Double) {
        guard samples.count > 1 else { return }
        let rc = 1.0 / (2.0 * .pi * cutoffHz)
        let dt = Float(1.0 / sampleRate)
        let alpha = rc / (rc + dt)

        // y[n] = α · (y[n−1] + x[n] − x[n−1]). Walks samples in place — no extra allocations.
        var prevX = samples[0]
        var prevY: Float = 0
        for i in 0..<samples.count {
            let x = samples[i]
            let y = alpha * (prevY + x - prevX)
            samples[i] = y
            prevX = x
            prevY = y
        }
    }

    /// One-shot speech cleanup applied before transcription / diarization / playback storage.
    /// Sequence is intentional: HPF first (removes DC + rumble that would inflate the RMS used
    /// by `loudnessNormalize`), then loudness pass to bring quiet recordings to a consistent
    /// listening level without clipping. ~2× realtime even on a busy CPU — orders of magnitude
    /// faster than ML denoise, and good enough for almost every "make this audible" scenario.
    static func cleanupAudio(samples: inout [Float], sampleRate: Double) {
        applyHighPassFilter(samples: &samples, cutoffHz: 80, sampleRate: sampleRate)
        loudnessNormalize(samples: &samples)
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

        // Per-window RMS via vDSP — ~10× faster than scalar Swift loop on 1h audio.
        let windowCount = samples.count / windowSamples
        guard windowCount > 0 else { return [] }
        var rms = [Float](repeating: 0, count: windowCount)
        let invWindow = 1.0 / Float(windowSamples)
        samples.withUnsafeBufferPointer { srcPtr in
            guard let base = srcPtr.baseAddress else { return }
            for w in 0..<windowCount {
                var sumSq: Float = 0
                vDSP_svesq(base.advanced(by: w * windowSamples), 1, &sumSq, vDSP_Length(windowSamples))
                rms[w] = Foundation.sqrt(sumSq * invWindow)
            }
        }

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
