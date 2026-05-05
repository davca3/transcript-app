import Foundation

/// Orchestrates: source audio → 48 kHz mono → cleanup (HPF + loudness) → store WAV →
/// resample to 16 kHz → transcribe + diarize → embed → identify → persist.
@MainActor
final class PipelineCoordinator {
    private let transcriber: TranscriptionService
    private let diarizer: DiarizationService
    private let embedder: SpeakerEmbeddingService
    private let identifier: SpeakerIdentifier
    private let recordings: RecordingStore
    private let speakers: SpeakerStore

    init(
        transcriber: TranscriptionService,
        diarizer: DiarizationService,
        embedder: SpeakerEmbeddingService,
        identifier: SpeakerIdentifier,
        recordings: RecordingStore,
        speakers: SpeakerStore
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.embedder = embedder
        self.identifier = identifier
        self.recordings = recordings
        self.speakers = speakers
    }

    /// Run the full pipeline on a source audio URL. The audio gets resampled to 16k mono and
    /// stored alongside the recording. Reports progress through the recording's status.
    /// Caller may pre-supply `id` so it can register a cancellable Task before the recording
    /// is upserted into the store; defaults to a fresh UUID for callers that don't care.
    func process(
        id: UUID = UUID(),
        sourceURL: URL,
        title: String,
        sourceKind: Recording.SourceKind,
        progress: @escaping (Recording) -> Void
    ) async {
        var rec = Recording(
            id: id,
            title: title,
            createdAt: Date(),
            duration: 0,
            sourceKind: sourceKind,
            status: .pending
        )
        try? FileManager.default.createDirectory(at: rec.folderURL, withIntermediateDirectories: true)

        do {
            try Task.checkCancellation()
            rec.status = .running(stage: .decoding, progress: 0.05)
            recordings.upsert(rec, persistImmediately: true); progress(rec)  // first insert → flush

            // Load at 48 kHz so the on-disk WAV plays back fully-bandwidth.
            var samples48k = try AudioUtils.loadAndResample(from: sourceURL, sampleRate: AudioUtils.storedSampleRate)
            rec.duration = TimeInterval(samples48k.count) / AudioUtils.storedSampleRate

            rec.status = .running(stage: .enhancing, progress: 0.1)
            recordings.upsert(rec); progress(rec)
            let cleanT0 = Date()

            // Stage 1: HPF on the shared buffer. Removes rumble that hurts both playback and
            // Whisper, but preserves the speech-vs-silence energy contrast that the silence-trim
            // VAD relies on.
            AudioUtils.applyHighPassFilter(
                samples: &samples48k,
                cutoffHz: 80,
                sampleRate: AudioUtils.storedSampleRate
            )

            // Pipeline branch: resample HPF'd-only audio to 16 kHz. Critically, no loudness
            // normalize here — the RMS-target gain compresses the speech-vs-noise dynamic
            // range that `AudioUtils.detectSpeech` reads as the "noise floor" to set its
            // adaptive threshold. With normalize applied, the trim was wiping out 99 % of
            // legitimate speech.
            let pipelineSamples = try AudioUtils.resample(
                samples: samples48k,
                from: AudioUtils.storedSampleRate,
                to: AudioUtils.targetSampleRate
            )

            // Storage branch: ALSO loudness-normalize so the saved WAV plays back at a
            // consistent listening level. Mutates the 48 kHz buffer in place — by the time
            // we write the WAV, the pipeline branch is already a separate copy at 16 kHz.
            AudioUtils.loudnessNormalize(samples: &samples48k)
            print(String(format: "[Pipeline] cleanup done in %.2fs", Date().timeIntervalSince(cleanT0)))
            try AudioUtils.writeWav(samples: samples48k, to: rec.audioURL, sampleRate: AudioUtils.storedSampleRate)

            try Task.checkCancellation()
            try await runStages(samples: pipelineSamples, rec: &rec, progress: progress)
        } catch is CancellationError {
            rec.status = .failed(message: "Zrušeno uživatelem")
            recordings.upsert(rec, persistImmediately: true); progress(rec)
            print("[Pipeline] process cancelled by user")
        } catch {
            rec.status = .failed(message: error.localizedDescription)
            recordings.upsert(rec, persistImmediately: true); progress(rec)
        }
    }

    /// Re-run transcription/diarization/identification on an existing recording's stored audio.
    /// Overwrites the prior transcript artifact. Speaker DB is unchanged.
    /// Skips cleanup — the stored WAV is already the cleaned version.
    func reprocess(_ recording: Recording, progress: @escaping (Recording) -> Void) async {
        var rec = recording
        do {
            try Task.checkCancellation()
            rec.status = .running(stage: .decoding, progress: 0.05)
            recordings.upsert(rec); progress(rec)
            let samples = try AudioUtils.loadAndResample(from: rec.audioURL)
            try Task.checkCancellation()
            try await runStages(samples: samples, rec: &rec, progress: progress)
        } catch is CancellationError {
            rec.status = .failed(message: "Zrušeno uživatelem")
            recordings.upsert(rec, persistImmediately: true); progress(rec)
            print("[Pipeline] reprocess cancelled by user")
        } catch {
            rec.status = .failed(message: error.localizedDescription)
            recordings.upsert(rec, persistImmediately: true); progress(rec)
        }
    }

    /// Shared transcribe → diarize → identify → stitch → persist path. Mutates `rec.status`
    /// through stages and reports each via the `progress` callback.
    private func runStages(
        samples: [Float],
        rec: inout Recording,
        progress: @escaping (Recording) -> Void
    ) async throws {
        rec.status = .running(stage: .transcribing, progress: 0.05)
        recordings.upsert(rec); progress(rec)

        // Trim silence for BOTH transcribe and diarize. Pyannote is the long pole — running
        // it on trimmed audio cuts wall time roughly proportionally to silence ratio.
        // Cluster turns come back in trimmed timeline; we translate them back to original.
        let (trimmedSamples, translate) = AudioUtils.trimSilence(samples: samples)
        let originalDur = TimeInterval(samples.count) / AudioUtils.targetSampleRate
        let trimmedDur = TimeInterval(trimmedSamples.count) / AudioUtils.targetSampleRate
        let savedPct = originalDur > 0 ? Int((originalDur - trimmedDur) / originalDur * 100) : 0
        print(String(format: "[Pipeline] silence-trim: %.1fs → %.1fs (saved %d%%)",
                     originalDur, trimmedDur, savedPct))

        // Estimate parallel wall time. On M1 Pro, observed (after chunked-parallel diarize):
        //   - Whisper turbo + parallel workers ≈ 25× realtime on trimmed audio
        //   - FluidAudio pyannote chunked across 6 parallel tasks ≈ 12–15× realtime
        // We use 12× as a slightly pessimistic estimate so the bar doesn't pin to 100% early.
        let transcribeEstimate = trimmedDur / 25.0
        let diarizeEstimate = trimmedDur / 12.0
        let parallelEstimate = Swift.max(transcribeEstimate, diarizeEstimate, 1.0)
        let parallelStart = Date()
        let recId = rec.id
        let store = recordings

        // Smooth progress driver: every 250ms updates rec.status with interpolated value.
        // Stage label flips from .transcribing → .diarizing at the halfway mark just to give
        // the user a sense of which phase is running (both run in parallel, but diarize tends
        // to be the long pole, so showing it for the second half is honest enough).
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(parallelStart)
                let phaseFrac = Swift.min(0.99, elapsed / parallelEstimate)
                let overall = 0.05 + 0.90 * phaseFrac
                let stage: Recording.ProcessingStatus.Stage = phaseFrac < 0.5 ? .transcribing : .diarizing
                if let idx = store.recordings.firstIndex(where: { $0.id == recId }) {
                    var r = store.recordings[idx]
                    r.status = .running(stage: stage, progress: overall)
                    store.upsert(r)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        async let transcriptTask: Transcript = transcriber.transcribe(samples: trimmedSamples, languageHint: nil)
        async let turnsTask: [SpeakerTurn] = diarizer.diarize(samples: trimmedSamples)

        let rawTranscript = try await transcriptTask
        let transcript = Transcript(
            segments: rawTranscript.segments.map {
                TranscriptSegment(id: $0.id, start: translate($0.start), end: translate($0.end), text: $0.text, speakerId: $0.speakerId)
            },
            detectedLanguage: rawTranscript.detectedLanguage
        )
        let rawTurns = try await turnsTask
        // Translate cluster turns from trimmed timeline back to original timeline. Embeddings
        // are per-turn (computed from speech audio) so they're unaffected by the trim.
        let turns = rawTurns.map {
            SpeakerTurn(start: translate($0.start), end: translate($0.end),
                        clusterId: $0.clusterId, embedding: $0.embedding)
        }
        progressTask.cancel()
        // Read back rec from the store (the timer may have updated it).
        if let updated = store.recordings.first(where: { $0.id == recId }) { rec = updated }

        rec.status = .running(stage: .identifying, progress: 0.8)
        recordings.upsert(rec); progress(rec)

        let rawClusterEmbeddings = try await computeClusterEmbeddings(turns: turns, samples: samples)
        // Auto-merge clusters that look like the same speaker (FluidAudio sometimes splits one
        // person across multiple clusters). Pure cosine merge — no DB lookup yet.
        let (mergedTurns, clusterEmbeddings) = mergeSimilarClusters(
            embeddings: rawClusterEmbeddings,
            turns: turns,
            threshold: 0.70
        )
        let assignments = identifier.assign(clusters: clusterEmbeddings)
        let (stitched, usedClusterIds) = stitch(transcript: transcript, turns: mergedTurns, assignments: assignments)
        // Drop "ghost" clusters that no segment ended up referencing (diarizer found a turn the
        // transcript never overlapped) — otherwise they appear as orphan chips with no text.
        let liveAssignments = assignments.filter { usedClusterIds.contains($0.key) }
        let liveEmbeddings = clusterEmbeddings.filter { usedClusterIds.contains($0.clusterId) }
        let stored = storedAssignments(from: liveAssignments, clusterEmbeddings: liveEmbeddings)

        let artifact = RecordingArtifact(transcript: stitched, clusterAssignments: stored)
        recordings.saveArtifact(artifact, for: rec)

        rec.status = .done
        recordings.upsert(rec, persistImmediately: true); progress(rec)  // terminal → flush
    }

    // MARK: - Cluster embeddings

    private func computeClusterEmbeddings(
        turns: [SpeakerTurn],
        samples: [Float]
    ) async throws -> [(clusterId: Int, embedding: [Float])] {
        let byCluster = Dictionary(grouping: turns, by: { $0.clusterId })
        var out: [(Int, [Float])] = []
        for (cid, group) in byCluster {
            // Prefer per-turn embeddings bundled by the diarizer (FluidAudio gives them);
            // fall back to slicing audio and calling embedder (StubDiarizer path).
            let pick = group.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(5)
            var sum: [Float] = []
            var n: Float = 0
            for t in pick {
                let emb: [Float]
                if let bundled = t.embedding, !bundled.isEmpty {
                    emb = bundled
                } else {
                    let slice = AudioUtils.slice(samples, from: t.start, to: t.end)
                    guard slice.count >= Int(AudioUtils.targetSampleRate * 0.8) else { continue }
                    emb = try await embedder.embed(samples: slice)
                }
                guard !emb.isEmpty else { continue }
                if sum.isEmpty {
                    sum = emb
                } else if emb.count == sum.count {
                    for i in 0..<sum.count { sum[i] += emb[i] }
                } else {
                    print("[Pipeline] cluster \(cid): skipping turn — embedding dim mismatch (\(emb.count) vs \(sum.count))")
                    continue
                }
                n += 1
            }
            guard n > 0 else { continue }
            let mean = sum.map { $0 / n }
            out.append((cid, l2(mean)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Merge clusters whose embeddings are too similar to be different speakers.
    /// Returns remapped turns (using compact new cluster ids) and the merged embeddings.
    private func mergeSimilarClusters(
        embeddings: [(clusterId: Int, embedding: [Float])],
        turns: [SpeakerTurn],
        threshold: Float
    ) -> (turns: [SpeakerTurn], embeddings: [(clusterId: Int, embedding: [Float])]) {
        let n = embeddings.count
        guard n > 1 else { return (turns, embeddings) }

        // Union-find over cluster indices in `embeddings`.
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = embeddings[i].embedding, b = embeddings[j].embedding
                guard a.count == b.count, !a.isEmpty else { continue }
                let sim = Cosine.similarity(a, b)
                if sim >= threshold {
                    let ri = find(i), rj = find(j)
                    if ri != rj { parent[ri] = rj }
                }
            }
        }

        // Build oldClusterId → newClusterId (compact, sorted by first appearance).
        var rootToNew: [Int: Int] = [:]
        var nextId = 0
        var oldToNew: [Int: Int] = [:]
        for i in 0..<n {
            let root = find(i)
            if let new = rootToNew[root] {
                oldToNew[embeddings[i].clusterId] = new
            } else {
                rootToNew[root] = nextId
                oldToNew[embeddings[i].clusterId] = nextId
                nextId += 1
            }
        }

        // Sum embeddings per merged group.
        var sums: [Int: ([Float], Float)] = [:]
        for ce in embeddings {
            let new = oldToNew[ce.clusterId]!
            if var sum = sums[new]?.0, let count = sums[new]?.1, sum.count == ce.embedding.count {
                for i in 0..<sum.count { sum[i] += ce.embedding[i] }
                sums[new] = (sum, count + 1)
            } else if sums[new] == nil {
                sums[new] = (ce.embedding, 1)
            }
        }
        let mergedEmbeddings: [(Int, [Float])] = sums.map { (newId, pair) in
            let (sum, count) = pair
            return (newId, l2(sum.map { $0 / count }))
        }.sorted { $0.0 < $1.0 }

        let mergedTurns = turns.map { t in
            SpeakerTurn(start: t.start, end: t.end, clusterId: oldToNew[t.clusterId] ?? t.clusterId, embedding: t.embedding)
        }

        let mergedCount = embeddings.count - mergedEmbeddings.count
        if mergedCount > 0 {
            print("[Pipeline] auto-merged \(mergedCount) cluster(s) (similarity ≥ \(threshold))")
        }

        return (mergedTurns, mergedEmbeddings)
    }

    private func l2(_ v: [Float]) -> [Float] {
        var s: Float = 0; for x in v { s += x * x }
        let n = sqrt(s)
        return n > 0 ? v.map { $0 / n } : v
    }

    // MARK: - Stitching

    /// Assign each transcript segment to the cluster whose turns overlap it most. Returns the
    /// stitched transcript plus the set of cluster ids that ended up referenced by ≥1 segment
    /// (so the caller can drop ghost clusters from stored assignments).
    private func stitch(
        transcript: Transcript,
        turns: [SpeakerTurn],
        assignments: [Int: SpeakerAssignment]
    ) -> (transcript: Transcript, usedClusterIds: Set<Int>) {
        var out = transcript
        var used = Set<Int>()
        for i in out.segments.indices {
            let seg = out.segments[i]
            let cid = dominantCluster(start: seg.start, end: seg.end, turns: turns)
            if let cid, let assignment = assignments[cid] {
                used.insert(cid)
                switch assignment {
                case .known(let speakerId, _, _):
                    out.segments[i].speakerId = speakerId
                case .unnamed:
                    out.segments[i].speakerId = UnnamedSpeakerID.make(clusterId: cid)
                }
            }
        }
        return (out, used)
    }

    private func dominantCluster(start: TimeInterval, end: TimeInterval, turns: [SpeakerTurn]) -> Int? {
        var overlapByCluster: [Int: TimeInterval] = [:]
        for t in turns {
            let lo = max(start, t.start)
            let hi = min(end, t.end)
            if hi > lo { overlapByCluster[t.clusterId, default: 0] += hi - lo }
        }
        return overlapByCluster.max(by: { $0.value < $1.value })?.key
    }

    private func storedAssignments(
        from assignments: [Int: SpeakerAssignment],
        clusterEmbeddings: [(clusterId: Int, embedding: [Float])]
    ) -> [String: StoredAssignment] {
        let embDict = Dictionary(uniqueKeysWithValues: clusterEmbeddings.map { ($0.clusterId, $0.embedding) })
        var out: [String: StoredAssignment] = [:]
        for (cid, a) in assignments {
            let emb = embDict[cid] ?? []
            switch a {
            case .known(let id, let name, _):
                out[String(cid)] = StoredAssignment(speakerId: id, displayName: name, embedding: emb)
            case .unnamed(let idx, _):
                out[String(cid)] = StoredAssignment(speakerId: nil, displayName: "Speaker \(idx)", embedding: emb)
            }
        }
        return out
    }

}
