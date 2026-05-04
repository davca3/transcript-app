import Foundation

/// A speaker turn produced by diarization: contiguous time range with a local cluster id
/// (0, 1, 2, … per recording — meaningless across recordings).
/// `embedding` is the per-turn speaker embedding when the diarizer provides one;
/// otherwise nil and the pipeline computes it via `SpeakerEmbeddingService`.
struct SpeakerTurn: Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var clusterId: Int
    var embedding: [Float]?
}

protocol DiarizationService {
    /// Diarize 16 kHz mono samples. Returns ordered turns covering the audio.
    func diarize(samples: [Float]) async throws -> [SpeakerTurn]
}

protocol SpeakerEmbeddingService {
    /// Returns a normalized embedding vector for 16 kHz mono samples.
    func embed(samples: [Float]) async throws -> [Float]
}
