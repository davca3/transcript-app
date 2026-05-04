import Foundation
#if canImport(FluidAudio)
import FluidAudio

/// Speaker diarization + per-turn speaker embeddings using FluidAudio (pyannote on Core ML).
/// Models are downloaded on first use and cached under the app's container.
@MainActor
final class FluidAudioDiarizer: DiarizationService, SpeakerEmbeddingService, ObservableObject {
    enum LoadingState: Equatable {
        case idle
        case downloading
        case loadingIntoMemory
        case ready
        case failed(String)
    }

    @Published private(set) var state: LoadingState = .idle

    private var manager: DiarizerManager?

    init() {}

    /// Preload diarization models in the background. Call from app launch.
    func preload() async {
        guard manager == nil else { return }
        print("[FluidAudio] preload start")
        let t0 = Date()
        state = .downloading
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            print("[FluidAudio] models downloaded/cached in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            state = .loadingIntoMemory
            let m = DiarizerManager(config: .default)
            m.initialize(models: models)
            self.manager = m
            self.state = .ready
            print("[FluidAudio] ready in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        } catch {
            self.state = .failed(error.localizedDescription)
            print("[FluidAudio] preload FAILED: \(error)")
        }
    }

    // MARK: - DiarizationService

    func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        let m = try await ensureLoaded()
        print("[FluidAudio] diarize \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000))s)")
        let t0 = Date()

        let result = try await m.performCompleteDiarization(samples, sampleRate: Int(AudioUtils.targetSampleRate))
        print("[FluidAudio] diarize done in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, segments=\(result.segments.count)")

        // FluidAudio gives string speaker IDs ("Speaker 1", "Speaker 2", ...) — map to ints stably.
        var idMap: [String: Int] = [:]
        var nextId = 0
        return result.segments.map { seg in
            let cid: Int
            if let existing = idMap[seg.speakerId] {
                cid = existing
            } else {
                cid = nextId
                idMap[seg.speakerId] = cid
                nextId += 1
            }
            return SpeakerTurn(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                clusterId: cid,
                embedding: l2Normalize(seg.embedding)
            )
        }
    }

    // MARK: - SpeakerEmbeddingService (fallback path; usually unused since diarize bundles embeddings)

    func embed(samples: [Float]) async throws -> [Float] {
        // FluidAudio doesn't expose a standalone embedding extractor; run a tiny diarization
        // and return the first segment's embedding.
        let turns = try await diarize(samples: samples)
        return turns.first?.embedding ?? []
    }

    // MARK: - Helpers

    private func ensureLoaded() async throws -> DiarizerManager {
        if let manager { return manager }
        await preload()
        if let manager { return manager }
        throw DiarizationError.notReady
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let n = sum.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}

enum DiarizationError: LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: return "Diarization model se nepodařilo načíst."
        }
    }
}
#endif
