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
    /// Banner only reveals if download takes >500ms — cache hits stay invisible.
    func preload() async {
        guard manager == nil else { return }
        print("[FluidAudio] preload start")
        let t0 = Date()
        state = .idle

        let revealBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, case .idle = self.state else { return }
            self.state = .downloading
        }

        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            print("[FluidAudio] models downloaded/cached in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            revealBannerTask.cancel()
            state = .loadingIntoMemory
            let m = DiarizerManager(config: .default)
            m.initialize(models: models)
            self.manager = m
            self.state = .ready
            print("[FluidAudio] ready in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        } catch {
            revealBannerTask.cancel()
            self.state = .failed(error.localizedDescription)
            print("[FluidAudio] preload FAILED: \(error)")
        }
    }

    // MARK: - DiarizationService

    /// Chunk length for parallel diarization. 3 min keeps enough speech context for stable
    /// cluster embeddings while small enough that even 10–15 min recordings get 4–5 chunks.
    private static let parallelChunkSeconds: Double = 180

    /// Max concurrent `performCompleteDiarization` calls. Each call holds ~1.5–2 GB peak — 6
    /// fits on M-series with 16 GB+ unified memory and keeps perf cores + ANE saturated.
    private static let parallelMaxConcurrent = 6

    func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        let m = try await ensureLoaded()
        let durationSec = Double(samples.count) / 16000
        print("[FluidAudio] diarize \(samples.count) samples (\(String(format: "%.1f", durationSec))s)")
        let t0 = Date()

        // Short audio: no benefit from chunking — single call is faster (no overhead, larger
        // clustering context). Threshold = 1.5× chunk so we don't split a "1 chunk + 30s tail".
        let chunkSec = Self.parallelChunkSeconds
        if durationSec < chunkSec * 1.5 {
            let result = try await m.performCompleteDiarization(samples, sampleRate: Int(AudioUtils.targetSampleRate))
            print("[FluidAudio] diarize done (single) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, segments=\(result.segments.count)")
            return mapSegments(result.segments, chunkIndex: 0)
        }

        // Build chunk ranges. Last chunk absorbs any remainder (so we never have a tiny tail < ~30s
        // with too little speech context for clustering).
        let chunkSamples = Int(chunkSec * AudioUtils.targetSampleRate)
        var ranges: [(idx: Int, start: Int, end: Int)] = []
        var s = 0
        var i = 0
        while s < samples.count {
            let remaining = samples.count - s
            let take = remaining < chunkSamples + chunkSamples / 2 ? remaining : chunkSamples
            ranges.append((i, s, s + take))
            s += take
            i += 1
        }

        let maxConcurrent = Self.parallelMaxConcurrent
        print("[FluidAudio] parallel diarize: \(ranges.count) chunk(s) of ~\(Int(chunkSec))s, max \(maxConcurrent) concurrent")

        // Throttled task group: keep at most `maxConcurrent` chunks in flight so RAM peak stays
        // bounded on long recordings. Order doesn't matter — turns are unioned.
        var collected: [SpeakerTurn] = []
        try await withThrowingTaskGroup(of: [SpeakerTurn].self) { group in
            var inFlight = 0
            var iter = ranges.makeIterator()

            func enqueueNext() {
                guard let r = iter.next() else { return }
                let chunkStartSec = TimeInterval(r.start) / TimeInterval(AudioUtils.targetSampleRate)
                let chunkSlice = Array(samples[r.start..<r.end])
                let idx = r.idx
                group.addTask { [self] in
                    let cT0 = Date()
                    let result = try await m.performCompleteDiarization(
                        chunkSlice,
                        sampleRate: Int(AudioUtils.targetSampleRate),
                        atTime: chunkStartSec
                    )
                    let elapsed = Date().timeIntervalSince(cT0)
                    print(String(format: "[FluidAudio]   chunk %d: %.1fs audio → %.1fs wall (%.1f× rt), %d segments",
                                 idx, Double(chunkSlice.count) / 16000, elapsed,
                                 (Double(chunkSlice.count) / 16000) / max(elapsed, 0.01),
                                 result.segments.count))
                    return self.mapSegments(result.segments, chunkIndex: idx)
                }
                inFlight += 1
            }

            for _ in 0..<min(maxConcurrent, ranges.count) { enqueueNext() }
            while inFlight > 0 {
                if let next = try await group.next() {
                    collected.append(contentsOf: next)
                    inFlight -= 1
                    enqueueNext()
                }
            }
        }

        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "[FluidAudio] parallel diarize done in %.1fs (%.1f× realtime), turns=%d",
                     elapsed, durationSec / max(elapsed, 0.01), collected.count))
        // Sort by start time so downstream stitching sees a chronological turn list.
        collected.sort { $0.start < $1.start }
        return collected
    }

    /// Map FluidAudio segments to `SpeakerTurn`s. `chunkIndex` namespaces cluster IDs so
    /// per-chunk-local "Speaker 1" labels don't collide across chunks. Cross-chunk merging is
    /// handled later by `PipelineCoordinator.mergeSimilarClusters` via cosine similarity.
    /// `nonisolated` so parallel chunk tasks can call it off the main actor.
    nonisolated private func mapSegments(_ segments: [TimedSpeakerSegment], chunkIndex: Int) -> [SpeakerTurn] {
        var idMap: [String: Int] = [:]
        var nextLocal = 0
        return segments.map { seg in
            let local: Int
            if let existing = idMap[seg.speakerId] {
                local = existing
            } else {
                local = nextLocal
                idMap[seg.speakerId] = local
                nextLocal += 1
            }
            let globalId = chunkIndex * 10_000 + local
            return SpeakerTurn(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                clusterId: globalId,
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

    nonisolated private func l2Normalize(_ v: [Float]) -> [Float] {
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
