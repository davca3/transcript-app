import Foundation
import WhisperKit

@MainActor
final class WhisperKitTranscriber: TranscriptionService, ObservableObject {
    enum LoadingState: Equatable {
        case idle
        case downloading(progress: Double)   // 0…1
        case loadingIntoMemory               // download done, warming up
        case ready
        case failed(String)
    }

    @Published private(set) var state: LoadingState = .idle

    private var pipe: WhisperKit?
    private let modelName: String

    /// Default: Whisper Turbo (`large-v3` distilled). ~5–8× faster than full large-v3 with
    /// near-equivalent cs/en quality. Roughly 600 MB download on first run.
    init(modelName: String = "openai_whisper-large-v3-v20240930_turbo") {
        self.modelName = modelName
    }

    /// Preload model in the background. Call from app launch so first transcription is instant.
    /// Two-phase: (1) download (with % progress), (2) load into memory + prewarm.
    func preload() async {
        guard pipe == nil else { return }
        print("[WhisperKit] preload start: model=\(modelName)")
        let t0 = Date()
        state = .downloading(progress: 0)

        do {
            // Phase 1: download via static method so we get progress.
            // Cached on subsequent runs → returns ~instantly.
            let lastLogged = LoggedProgress()
            let folderURL = try await WhisperKit.download(
                variant: modelName,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { progress in
                    let frac = progress.fractionCompleted
                    let completed = progress.completedUnitCount
                    let total = progress.totalUnitCount
                    if lastLogged.shouldLog(frac: frac) {
                        print(String(format: "[WhisperKit] download progress %.1f%% (%lld / %lld)",
                                     frac * 100, completed, total))
                    }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Drop late-firing callbacks once we've moved past the download phase.
                        // Without this guard, a backlog of queued Tasks publishes state changes
                        // during the SwiftUI re-render that's removing the banner.
                        if case .downloading = self.state {
                            self.state = .downloading(progress: frac)
                        }
                    }
                }
            )
            print("[WhisperKit] download done in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s → \(folderURL.path)")

            // Phase 2: load WITHOUT prewarm (prewarm hangs on sandboxed macOS for large models).
            // First transcribe will be a few seconds slower but the app won't sit forever.
            state = .loadingIntoMemory
            let t1 = Date()
            print("[WhisperKit] loading model into memory (prewarm disabled)…")
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: folderURL.path,
                verbose: true,
                prewarm: false,
                load: true,
                download: false
            )
            let p = try await WhisperKit(config)
            self.pipe = p
            self.state = .ready
            print("[WhisperKit] load done in \(String(format: "%.1f", Date().timeIntervalSince(t1)))s (total \(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
        } catch {
            self.state = .failed(error.localizedDescription)
            print("[WhisperKit] preload FAILED: \(error)")
        }
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> Transcript {
        let pipe = try await ensureLoaded()
        let durationSec = Double(samples.count) / 16000
        print("[WhisperKit] transcribe \(samples.count) samples (\(String(format: "%.1f", durationSec))s)")
        let t0 = Date()

        // Parallel chunks: significantly speeds up long meetings on Apple Silicon.
        // Leave 2 cores for OS + diarizer, cap at 8 to avoid memory pressure on long audio.
        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageHint,
            temperature: 0.0,
            sampleLength: 224,
            usePrefillPrompt: true,
            detectLanguage: languageHint == nil,
            skipSpecialTokens: true,
            wordTimestamps: false,
            concurrentWorkerCount: workers,
            chunkingStrategy: .vad
        )

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(t0)
        let xRealtime = durationSec / max(elapsed, 0.01)
        print(String(format: "[WhisperKit] transcribe done in %.1fs (%.1f× realtime, %d worker(s)), results=%d",
                     elapsed, xRealtime, workers, results.count))

        var segments: [TranscriptSegment] = []
        var language: String?
        for r in results {
            if language == nil { language = r.language }
            for s in r.segments {
                let raw: String = s.text
                let text = Self.cleanText(raw)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    start: TimeInterval(s.start),
                    end: TimeInterval(s.end),
                    text: text
                ))
            }
        }
        return Transcript(segments: segments, detectedLanguage: language)
    }

    /// Strip Whisper special tokens like `<|startoftranscript|>` and trim.
    /// `skipSpecialTokens: true` should already do this; this is a defensive belt+suspenders.
    private static let specialTokenRegex = try! NSRegularExpression(pattern: #"<\|[^|]*\|>"#)
    private static func cleanText(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = specialTokenRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private func ensureLoaded() async throws -> WhisperKit {
        if let pipe { return pipe }
        await preload()
        if let pipe { return pipe }
        throw TranscriptionError.loadFailed
    }
}

enum TranscriptionError: LocalizedError {
    case loadFailed
    var errorDescription: String? {
        switch self {
        case .loadFailed: return "Whisper model se nepodařilo načíst."
        }
    }
}

/// Throttles progress logging — print every full percent + total/completed units once per second max.
private final class LoggedProgress: @unchecked Sendable {
    private var lastFrac: Double = -1
    private var lastTime = Date.distantPast
    private let lock = NSLock()

    func shouldLog(frac: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let bigJump = abs(frac - lastFrac) >= 0.01
        let timePassed = now.timeIntervalSince(lastTime) >= 1.0
        guard bigJump || timePassed else { return false }
        lastFrac = frac
        lastTime = now
        return true
    }
}
