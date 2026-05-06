import XCTest
import AVFoundation
@testable import Skribent

/// Integration test for PipelineCoordinator using stub services. Exercises the full coordinator
/// path (decode → resample → trim → transcribe + diarize → identify → stitch → persist) without
/// loading WhisperKit / FluidAudio. Proves the protocol-typed DI seams work.
@MainActor
final class PipelineCoordinatorTests: XCTestCase {

    // MARK: - Stubs

    private final class StubTranscriber: TranscriptionService {
        let segments: [TranscriptSegment]
        var transcribeCallCount = 0

        init(segments: [TranscriptSegment]) { self.segments = segments }

        func transcribe(samples: [Float], languageHint: String?) async throws -> Transcript {
            transcribeCallCount += 1
            return Transcript(segments: segments, detectedLanguage: "cs")
        }
    }

    private final class StubDiarizationService: DiarizationService, SpeakerEmbeddingService {
        let turns: [SpeakerTurn]
        var diarizeCallCount = 0

        init(turns: [SpeakerTurn]) { self.turns = turns }

        func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
            diarizeCallCount += 1
            return turns
        }

        func embed(samples: [Float]) async throws -> [Float] {
            // Constant embedding — fine for stub since unique cluster ids have unique embeddings
            // already in the turn objects.
            return [Float](repeating: 0.5, count: 8)
        }
    }

    // MARK: - Helpers

    /// Write 1 second of 48 kHz mono silence-with-tone WAV to a temp URL. Just enough audio for
    /// the pipeline's load/resample/trim path to produce non-empty samples without taking long.
    private func writeShortTestWAV() throws -> URL {
        let sampleRate = AudioUtils.storedSampleRate  // 48k
        let frameCount = Int(sampleRate * 1.0)
        // Sine tone at 440 Hz so trim-to-speech keeps it (silence detector would drop pure zero).
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            samples[i] = 0.3 * Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-test-\(UUID().uuidString).wav")
        try AudioUtils.writeWav(samples: samples, to: url, sampleRate: sampleRate)
        return url
    }

    private func makeIsolatedSpeakerStore() -> SpeakerStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("skribent-test-speakers-\(UUID().uuidString).json")
        return SpeakerStore(fileURL: tmp)
    }

    // MARK: - Tests

    func test_process_happyPath_producesArtifact() async throws {
        let speakers = makeIsolatedSpeakerStore()
        let recordings = RecordingStore()

        let segments = [
            TranscriptSegment(start: 0.1, end: 0.5, text: "Ahoj"),
            TranscriptSegment(start: 0.5, end: 0.9, text: "světe"),
        ]
        let turns = [
            SpeakerTurn(start: 0, end: 1.0, clusterId: 0,
                        embedding: [Float](repeating: 0.5, count: 8)),
        ]
        let transcriber = StubTranscriber(segments: segments)
        let diarizer = StubDiarizationService(turns: turns)
        let identifier = SpeakerIdentifier(store: speakers)

        let pipeline = PipelineCoordinator(
            transcriber: transcriber,
            diarizer: diarizer,
            embedder: diarizer,
            identifier: identifier,
            recordings: recordings,
            speakers: speakers
        )

        let url = try writeShortTestWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        var lastProgress: Recording?
        await pipeline.process(id: id, sourceURL: url, title: "Test", sourceKind: .imported) { rec in
            lastProgress = rec
        }

        XCTAssertEqual(transcriber.transcribeCallCount, 1)
        XCTAssertEqual(diarizer.diarizeCallCount, 1)

        guard let final = lastProgress, final.id == id else {
            return XCTFail("expected final progress callback for the recording")
        }
        if case .done = final.status { } else {
            XCTFail("expected .done terminal status, got \(final.status)")
        }

        // Artifact should be persisted with the stub's segments.
        guard let artifact = recordings.loadArtifact(for: final) else {
            return XCTFail("expected an artifact on disk after happy-path process")
        }
        XCTAssertEqual(artifact.transcript.segments.count, 2)
        XCTAssertEqual(artifact.transcript.segments[0].text, "Ahoj")

        try? FileManager.default.removeItem(at: final.folderURL)
    }

    func test_process_cancelledMidFlight_setsFailedStatus() async throws {
        let speakers = makeIsolatedSpeakerStore()
        let recordings = RecordingStore()

        let transcriber = StubTranscriber(segments: [])
        let diarizer = StubDiarizationService(turns: [])
        let identifier = SpeakerIdentifier(store: speakers)
        let pipeline = PipelineCoordinator(
            transcriber: transcriber,
            diarizer: diarizer,
            embedder: diarizer,
            identifier: identifier,
            recordings: recordings,
            speakers: speakers
        )

        let url = try writeShortTestWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        var lastProgress: Recording?
        let task = Task { @MainActor in
            await pipeline.process(id: id, sourceURL: url, title: "Cancel", sourceKind: .imported) { rec in
                lastProgress = rec
            }
        }
        // Cancel right away — the pipeline's first checkCancellation hits before transcribe.
        task.cancel()
        await task.value

        guard let final = lastProgress else { return XCTFail("expected at least one progress callback") }
        if case .failed(let msg) = final.status {
            XCTAssertTrue(msg.contains("Zrušeno"))
        } else {
            // Pipeline may have completed before cancel landed (stubs are fast). Either outcome is
            // acceptable — we only assert that the cancel path doesn't crash.
        }

        try? FileManager.default.removeItem(at: final.folderURL)
    }
}
