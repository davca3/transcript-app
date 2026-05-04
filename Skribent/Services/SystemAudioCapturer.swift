import Foundation
import AVFoundation
import ScreenCaptureKit

/// Captures system output audio using ScreenCaptureKit and writes it to a CAF file.
/// macOS 13+. Requires Screen Recording permission (System Settings → Privacy & Security).
@available(macOS 13.0, *)
final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CapturerError: LocalizedError {
        case noDisplay
        case noContent(String)
        case alreadyRunning
        case writeSetupFailed(String)
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Žádný displej k dispozici pro capture systémového audia."
            case .noContent(let msg): return "Nepovedlo se získat content: \(msg)"
            case .alreadyRunning: return "System audio capture už běží."
            case .writeSetupFailed(let msg): return "Selhalo nastavení zápisu audia: \(msg)"
            }
        }
    }

    private(set) var outputURL: URL?
    private var stream: SCStream?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "skribent.systemAudio")

    /// Start capturing. Writes a CAF file in the temp directory; URL available in `outputURL`.
    func start() async throws {
        guard stream == nil else { throw CapturerError.alreadyRunning }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CapturerError.noContent(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw CapturerError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We don't care about video — keep it minimal to save CPU.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skribent-sysaudio-\(UUID().uuidString).caf")
        self.outputURL = url

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
            self.stream = stream
            print("[SystemAudio] capture started → \(url.path)")
        } catch {
            self.stream = nil
            self.outputURL = nil
            throw error
        }
    }

    /// Stop capturing. Returns the URL of the recorded file (or nil if never started).
    @discardableResult
    func stop() async -> URL? {
        guard let s = stream else { return outputURL }
        do {
            try await s.stopCapture()
        } catch {
            print("[SystemAudio] stopCapture error: \(error)")
        }
        stream = nil
        file = nil
        print("[SystemAudio] stopped → \(outputURL?.path ?? "nil")")
        return outputURL
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        do {
            if file == nil, let url = outputURL {
                let settings = pcmBuffer.format.settings
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: pcmBuffer.format.commonFormat,
                                       interleaved: pcmBuffer.format.isInterleaved)
            }
            try file?.write(from: pcmBuffer)
        } catch {
            print("[SystemAudio] write error: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[SystemAudio] stream stopped with error: \(error)")
    }
}

@available(macOS 13.0, *)
private extension CMSampleBuffer {
    /// Convert a CoreMedia sample buffer (audio) to an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let format = AVAudioFormat(streamDescription: asbd)
        guard let format else { return nil }

        let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numFrames) else { return nil }
        pcm.frameLength = numFrames

        let blockBuffer = CMSampleBufferGetDataBuffer(self)
        var lengthAtOffsetOut: Int = 0
        var totalLengthOut: Int = 0
        var dataPointerOut: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer!,
                                          atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffsetOut,
                                          totalLengthOut: &totalLengthOut,
                                          dataPointerOut: &dataPointerOut) == noErr,
              let src = dataPointerOut else { return nil }

        if format.isInterleaved {
            // Single audio buffer for all channels.
            memcpy(pcm.audioBufferList.pointee.mBuffers.mData, src, totalLengthOut)
        } else {
            // Non-interleaved: copy whole block; ScreenCaptureKit packs deinterleaved per format.
            let dstBuffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            let bytesPerChannel = totalLengthOut / dstBuffers.count
            for i in 0..<dstBuffers.count {
                memcpy(dstBuffers[i].mData, src.advanced(by: i * bytesPerChannel), bytesPerChannel)
            }
        }
        return pcm
    }
}
