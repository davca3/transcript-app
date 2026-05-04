import Foundation

protocol TranscriptionService {
    /// Transcribe 16 kHz mono Float32 samples. Returns segments with start/end + detected language.
    func transcribe(samples: [Float], languageHint: String?) async throws -> Transcript
}
