import Foundation

/// Orchestrates: source audio → 16k mono PCM → transcribe → diarize → embed → identify → persist.
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
    func process(
        sourceURL: URL,
        title: String,
        sourceKind: Recording.SourceKind,
        progress: @escaping (Recording) -> Void
    ) async {
        var rec = Recording(
            id: UUID(),
            title: title,
            createdAt: Date(),
            duration: 0,
            sourceKind: sourceKind,
            status: .pending
        )
        try? FileManager.default.createDirectory(at: rec.folderURL, withIntermediateDirectories: true)

        do {
            rec.status = .running(stage: .decoding, progress: 0.1)
            recordings.upsert(rec); progress(rec)
            let samples = try AudioUtils.loadAndResample(from: sourceURL)
            rec.duration = TimeInterval(samples.count) / AudioUtils.targetSampleRate
            try AudioUtils.writeWav(samples: samples, to: rec.audioURL)
            try await runStages(samples: samples, rec: &rec, progress: progress)
        } catch {
            rec.status = .failed(message: error.localizedDescription)
            recordings.upsert(rec); progress(rec)
        }
    }

    /// Re-run transcription/diarization/identification on an existing recording's stored audio.
    /// Overwrites the prior transcript artifact. Speaker DB is unchanged.
    func reprocess(_ recording: Recording, progress: @escaping (Recording) -> Void) async {
        var rec = recording
        do {
            rec.status = .running(stage: .decoding, progress: 0.05)
            recordings.upsert(rec); progress(rec)
            let samples = try AudioUtils.loadAndResample(from: rec.audioURL)
            // Audio is already 16k mono WAV — don't rewrite it.
            try await runStages(samples: samples, rec: &rec, progress: progress)
        } catch {
            rec.status = .failed(message: error.localizedDescription)
            recordings.upsert(rec); progress(rec)
        }
    }

    /// Shared transcribe → diarize → identify → stitch → persist path. Mutates `rec.status`
    /// through stages and reports each via the `progress` callback.
    private func runStages(
        samples: [Float],
        rec: inout Recording,
        progress: @escaping (Recording) -> Void
    ) async throws {
        rec.status = .running(stage: .transcribing, progress: 0.25)
        recordings.upsert(rec); progress(rec)

        // Trim silence ONLY for transcription — speeds Whisper up significantly on long
        // recordings with pauses. The original samples (and audio.wav on disk) are untouched;
        // we translate Whisper's timestamps back into the original timeline before stitching.
        let (trimmedSamples, translate) = AudioUtils.trimSilence(samples: samples)
        let originalDur = TimeInterval(samples.count) / AudioUtils.targetSampleRate
        let trimmedDur = TimeInterval(trimmedSamples.count) / AudioUtils.targetSampleRate
        let savedPct = originalDur > 0 ? Int((originalDur - trimmedDur) / originalDur * 100) : 0
        print(String(format: "[Pipeline] silence-trim: %.1fs → %.1fs (saved %d%%)",
                     originalDur, trimmedDur, savedPct))

        // Run Whisper (on trimmed) + diarization (on full original) in parallel.
        // Both can want the ANE; Core ML gracefully falls back to GPU/CPU when contended,
        // which produces noisy "ANEProgramProcessRequestDirect Failed status=0xf" logs but
        // still completes the inference. Trade noise for ~30-50% wall-clock speedup.
        async let transcriptTask: Transcript = transcriber.transcribe(samples: trimmedSamples, languageHint: nil)
        async let turnsTask: [SpeakerTurn] = diarizer.diarize(samples: samples)

        let rawTranscript = try await transcriptTask
        let transcript = Transcript(
            segments: rawTranscript.segments.map {
                TranscriptSegment(id: $0.id, start: translate($0.start), end: translate($0.end), text: $0.text, speakerId: $0.speakerId)
            },
            detectedLanguage: rawTranscript.detectedLanguage
        )

        rec.status = .running(stage: .diarizing, progress: 0.6)
        recordings.upsert(rec); progress(rec)
        let turns = try await turnsTask

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
        let stitched = stitch(transcript: transcript, turns: mergedTurns, assignments: assignments)
        let stored = storedAssignments(from: assignments, clusterEmbeddings: clusterEmbeddings)

        let artifact = RecordingArtifact(transcript: stitched, clusterAssignments: stored)
        recordings.saveArtifact(artifact, for: rec)

        rec.status = .done
        recordings.upsert(rec); progress(rec)
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

    /// Assign each transcript segment to the cluster whose turns overlap it most.
    private func stitch(
        transcript: Transcript,
        turns: [SpeakerTurn],
        assignments: [Int: SpeakerAssignment]
    ) -> Transcript {
        var out = transcript
        for i in out.segments.indices {
            let seg = out.segments[i]
            let cid = dominantCluster(start: seg.start, end: seg.end, turns: turns)
            if let cid, let assignment = assignments[cid] {
                switch assignment {
                case .known(let speakerId, _, _):
                    out.segments[i].speakerId = speakerId
                case .unnamed:
                    out.segments[i].speakerId = UnnamedSpeakerID.make(clusterId: cid)
                }
            }
        }
        return out
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
