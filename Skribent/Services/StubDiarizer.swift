import Foundation

/// Fallback used when sherpa-onnx isn't wired in (or its Swift API doesn't match).
/// Treats the entire recording as a single speaker. Produces a deterministic,
/// constant embedding so identification still works (everyone matches "Speaker 1"
/// after the first naming).
final class StubDiarizer: DiarizationService, SpeakerEmbeddingService {
    private let embeddingDim = 192

    func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        let duration = TimeInterval(samples.count) / AudioUtils.targetSampleRate
        return [SpeakerTurn(start: 0, end: duration, clusterId: 0, embedding: nil)]
    }

    func embed(samples: [Float]) async throws -> [Float] {
        // Use mean+stddev of mel-ish energy bins as a *very* crude signature.
        // Better than constant zero: lets the cosine matcher discriminate slightly.
        guard !samples.isEmpty else { return Array(repeating: 0, count: embeddingDim) }
        let chunk = max(1, samples.count / embeddingDim)
        var emb = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<embeddingDim {
            let lo = i * chunk
            let hi = min(samples.count, lo + chunk)
            guard lo < hi else { break }
            var s: Float = 0
            for j in lo..<hi { s += abs(samples[j]) }
            emb[i] = s / Float(hi - lo)
        }
        // L2 normalize
        var sum: Float = 0; for v in emb { sum += v * v }
        let n = sum.squareRoot()
        return n > 0 ? emb.map { $0 / n } : emb
    }
}
