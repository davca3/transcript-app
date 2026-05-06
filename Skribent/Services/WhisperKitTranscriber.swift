import CoreML
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

    /// UserDefaults key for the "Use Apple Neural Engine" toggle in Settings. ANE is
    /// off by default because cold-start ANE compilation can take 5–15 minutes for the
    /// large-v3-turbo model and looks indistinguishable from a hang to the user. Power
    /// users can opt in via `Settings → Akcelerace přepisu`.
    static let useANEDefaultsKey = "useAppleNeuralEngine"

    /// Default: full `large-v3`. Picked over the distilled `_turbo` variant because turbo's
    /// quality drop on Czech (especially deformed phonemes, fast/overlapping speech, and rare
    /// vocabulary) showed up as gibberish words the refiner couldn't recover ("Vynáhle",
    /// "zároveŽá"). Full v3 is ~3-5× slower but markedly better at acoustic edge cases.
    /// ~1.5 GB download on first run; ~10× realtime on M-series Macs.
    /// To swap to faster/smaller variants:
    ///   - `openai_whisper-large-v3-v20240930_turbo` (~600 MB, ~50× realtime, weaker on hard CS audio)
    ///   - `openai_whisper-base` (~150 MB, very fast, much weaker quality)
    init(modelName: String = "openai_whisper-large-v3-v20240930") {
        self.modelName = modelName
    }

    /// Inspect the WhisperKit / HF-Hub cache directly. If the model is already on disk we skip
    /// `WhisperKit.download(...)` entirely — that call takes 5+ seconds even for cache hits
    /// (validation + remote file listing), which is what makes the banner blink on every launch.
    private func cachedModelFolder() -> URL? {
        let folder = AppPaths.documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
        let marker = folder.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: marker.path) ? folder : nil
    }

    /// Preload model in the background. Call from app launch so first transcription is instant.
    func preload() async {
        guard pipe == nil else { return }
        Log.transcriber.info("preload start: model=\(self.modelName, privacy: .public)")
        let t0 = Date()
        state = .idle

        let folderURL: URL
        if let cached = cachedModelFolder() {
            Log.transcriber.info("cache hit → \(cached.path, privacy: .public) (skipping download)")
            folderURL = cached
        } else {
            // Real download path: reveal banner after 500ms (so very fast networks still skip it).
            let revealBannerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, case .idle = self.state else { return }
                self.state = .downloading(progress: 0)
            }
            do {
                let lastLogged = LoggedProgress()
                folderURL = try await WhisperKit.download(
                    variant: modelName,
                    from: "argmaxinc/whisperkit-coreml",
                    progressCallback: { progress in
                        let frac = progress.fractionCompleted
                        if lastLogged.shouldLog(frac: frac) {
                            Log.transcriber.info("download progress \(frac * 100, format: .fixed(precision: 1), privacy: .public)% (\(progress.completedUnitCount, privacy: .public) / \(progress.totalUnitCount, privacy: .public))")
                        }
                        Task { @MainActor [weak self] in
                            guard let self, case .downloading = self.state else { return }
                            self.state = .downloading(progress: frac)
                        }
                    }
                )
                revealBannerTask.cancel()
                Log.transcriber.info("download done in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1), privacy: .public)s → \(folderURL.path, privacy: .public)")
            } catch {
                revealBannerTask.cancel()
                self.state = .failed(error.localizedDescription)
                Log.transcriber.error("preload FAILED (download): \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // Load (no prewarm — hangs on sandboxed macOS for large models).
        // ANE compute is opt-in via Settings: when off, force CPU+GPU on every stage to skip
        // ANE AOT compilation (which can take 5–15 minutes on cold cache and is what makes the
        // app look hung). When on, pass `nil` so WhisperKit picks its ANE-friendly defaults.
        let useANE = UserDefaults.standard.bool(forKey: Self.useANEDefaultsKey)
        let computeOptions: ModelComputeOptions? = useANE ? nil : ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuAndGPU
        )
        state = .loadingIntoMemory
        let t1 = Date()
        Log.transcriber.info("loading model into memory (prewarm disabled, ANE \(useANE ? "ENABLED" : "disabled", privacy: .public))…")
        do {
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: folderURL.path,
                computeOptions: computeOptions,
                verbose: true,
                prewarm: false,
                load: true,
                download: false
            )
            let p = try await WhisperKit(config)
            self.pipe = p
            self.state = .ready
            Log.transcriber.info("load done in \(Date().timeIntervalSince(t1), format: .fixed(precision: 1), privacy: .public)s (total \(Date().timeIntervalSince(t0), format: .fixed(precision: 1), privacy: .public)s)")
        } catch {
            self.state = .failed(error.localizedDescription)
            Log.transcriber.error("preload FAILED (load): \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> Transcript {
        let pipe = try await ensureLoaded()
        let durationSec = Double(samples.count) / 16000
        Log.transcriber.info("transcribe \(samples.count, privacy: .public) samples (\(durationSec, format: .fixed(precision: 1), privacy: .public)s)")
        let t0 = Date()

        // Parallel chunks: significantly speeds up long meetings on Apple Silicon.
        // Leave 2 cores for OS + diarizer, cap at 8 to avoid memory pressure on long audio.
        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageHint,
            temperature: 0.0,
            temperatureFallbackCount: 2,   // default ~5; cuts retry overhead on hard chunks
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
        Log.transcriber.info("transcribe done in \(elapsed, format: .fixed(precision: 1), privacy: .public)s (\(xRealtime, format: .fixed(precision: 1), privacy: .public)× realtime, \(workers, privacy: .public) worker(s)), results=\(results.count, privacy: .public)")

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
    // Safe: literal pattern, NSRegularExpression compile cannot throw at runtime.
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
