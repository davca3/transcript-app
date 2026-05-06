import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    let speakers: SpeakerStore
    let recordings: RecordingStore
    let recorder: AudioRecorder

    @Published var selectedRecordingId: UUID?
    @Published var globalError: String?
    /// Transient detail string (e.g. "3.4 GB z 7.0 GB" while downloading the refiner model).
    /// Bound to the recording currently being processed; cleared automatically when the
    /// active phase doesn't have meaningful sub-info.
    @Published var processingDetail: String?

    let pipeline: PipelineCoordinator
    let transcriber: WhisperKitTranscriber
    #if canImport(FluidAudio)
    let diarizer: FluidAudioDiarizer
    #endif

    private var cancellables = Set<AnyCancellable>()

    /// In-flight processing tasks keyed by recording id. Used so the UI's "Zrušit" button can
    /// cancel exactly the task running on the currently-visible recording. Tasks are removed
    /// from the map at the end of their body (success or failure path), so a stale entry only
    /// survives until the next pass through the run loop.
    private var inflightTasks: [UUID: Task<Void, Never>] = [:]

    /// Recordings whose Task has been .cancel()'d but hasn't yet unwound to a terminal status.
    /// Drives the "Ruším…" spinner in `ProgressBanner` so the user gets feedback during the gap
    /// between clicking Zrušit and the catch site flipping status to `.failed`.
    @Published private(set) var cancellingIds: Set<UUID> = []

    /// Designated initializer with injectable collaborators. Defaults wire the production
    /// classes; tests pass in-memory stores and lightweight stubs to avoid touching disk and
    /// loading multi-GB ML models. Pipeline always runs against the protocol-typed services
    /// (TranscriptionService / DiarizationService / SpeakerEmbeddingService), so a stub-driven
    /// integration test can exercise the full coordinator without WhisperKit / FluidAudio.
    init(
        speakers: SpeakerStore? = nil,
        recordings: RecordingStore? = nil,
        recorder: AudioRecorder? = nil,
        transcriber: WhisperKitTranscriber? = nil,
        pipelineTranscriber: TranscriptionService? = nil,
        pipelineDiarizer: DiarizationService? = nil,
        pipelineEmbedder: SpeakerEmbeddingService? = nil,
        autoPreload: Bool = true
    ) {
        // Defaults are constructed lazily inside the body because @MainActor classes can't be
        // referenced from non-isolated default-argument expressions. Tests pass explicit
        // instances; production calls AppState() and gets the standard wiring.
        let speakers = speakers ?? SpeakerStore()
        let recordings = recordings ?? RecordingStore()
        let recorder = recorder ?? AudioRecorder()
        let transcriber = transcriber ?? WhisperKitTranscriber()
        self.speakers = speakers
        self.recordings = recordings
        self.recorder = recorder
        self.transcriber = transcriber

        let diarizationService: DiarizationService
        let embeddingService: SpeakerEmbeddingService
        #if canImport(FluidAudio)
        let fluid = FluidAudioDiarizer()
        self.diarizer = fluid
        diarizationService = pipelineDiarizer ?? fluid
        embeddingService = pipelineEmbedder ?? fluid
        #else
        let stub = StubDiarizer()
        diarizationService = pipelineDiarizer ?? stub
        embeddingService = pipelineEmbedder ?? stub
        #endif

        let identifier = SpeakerIdentifier(store: speakers)
        self.pipeline = PipelineCoordinator(
            transcriber: pipelineTranscriber ?? transcriber,
            diarizer: diarizationService,
            embedder: embeddingService,
            identifier: identifier,
            recordings: recordings,
            speakers: speakers
        )

        // NB: We intentionally do NOT forward recordings/speakers objectWillChange to AppState.
        // That would re-render every view that observes AppState whenever any store mutates,
        // including during pipeline stage updates (5×/recording). Views that need a store
        // declare it as their own @EnvironmentObject (see SkribentApp).

        // Surface store-level persistence failures via globalError so the UI banner can show them
        // instead of silently dropping the error to the log. Each store publishes `lastError`
        // independently — we coalesce both into the single AppState-owned globalError channel.
        recordings.$lastError
            .compactMap { $0?.localizedDescription }
            .receive(on: RunLoop.main)
            .assign(to: \.globalError, on: self)
            .store(in: &cancellables)
        speakers.$lastError
            .compactMap { $0?.localizedDescription }
            .receive(on: RunLoop.main)
            .assign(to: \.globalError, on: self)
            .store(in: &cancellables)

        // Warm up models sequentially. Parallel cold-start peaks ~3–4 GB during simultaneous
        // ANE graph compilation (Whisper Turbo + pyannote + wespeaker) and gets jetsamed on
        // 16 GB Macs. Sequential adds ~5–10 s to TTFR but survives cold cache.
        // Skipped in tests via autoPreload=false to keep them under a second.
        if autoPreload {
            Task {
                await transcriber.preload()
                #if canImport(FluidAudio)
                await fluid.preload()
                #endif
            }
        }
    }

    func processNewRecording(sourceURL: URL, title: String, kind: Recording.SourceKind) {
        // Pre-generate the recording id so we can register the task BEFORE the recording is
        // upserted into the store. Otherwise the user could click Cancel between recording
        // creation and our first opportunity to register, and we'd fail to cancel.
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pipeline.process(id: id, sourceURL: sourceURL, title: title, sourceKind: kind) { [weak self] rec in
                Task { @MainActor in
                    self?.selectedRecordingId = rec.id
                }
            }
            self.inflightTasks[id] = nil
            self.cancellingIds.remove(id)
        }
        inflightTasks[id] = task
    }

    func regenerateTranscript(for recording: Recording) {
        let id = recording.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pipeline.reprocess(recording) { _ in }
            self.inflightTasks[id] = nil
            self.cancellingIds.remove(id)
        }
        inflightTasks[id] = task
    }

    /// Cancel whatever pipeline / refine task is currently running on this recording. No-op if
    /// nothing is running. The task body sees `Task.isCancelled` and updates the recording's
    /// status accordingly (.failed for pipeline mid-flight, reverts to .done for refine since
    /// the original transcript is still intact). The id is parked in `cancellingIds` so the UI
    /// shows a spinner during the unwind window.
    func cancelProcessing(for recording: Recording) {
        if let task = inflightTasks[recording.id] {
            Log.app.info("cancelling in-flight task for \(recording.id, privacy: .public)")
            cancellingIds.insert(recording.id)
            task.cancel()
        }
    }

    /// Delete a recording, cancelling its in-flight pipeline task first. Without the upfront
    /// cancel, the pipeline's catch site would keep writing to disk (status flip + saveArtifact)
    /// after `recordings.delete(...)` already removed the index entry, leaving orphaned files.
    func deleteRecording(_ id: UUID) {
        if let task = inflightTasks[id] {
            Log.app.info("deleting recording with in-flight task — cancelling first: \(id, privacy: .public)")
            task.cancel()
            inflightTasks[id] = nil
            cancellingIds.remove(id)
        }
        recordings.delete(id)
    }

    /// Format Foundation's `Progress` byte counts into a Czech "completed z total" string for
    /// the progress banner. Falls back to file-count format if the Hub API uses unit counts
    /// instead of bytes (it usually doesn't, but `LLMEvaluator` upstream guards for it).
    private static func formatDownloadDetail(completed: Int64, total: Int64) -> String? {
        guard total > 0 else { return nil }
        if total < 100 {
            // Heuristic: small unit count = file-based progress, not bytes.
            return "Soubor \(completed + 1) z \(total)"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: completed)) z \(formatter.string(fromByteCount: total))"
    }

    /// LLM-assisted cleanup of an existing transcript via a local Qwen model running on Ollama.
    /// Only updates the `text` field of each segment — timestamps + speaker assignments +
    /// cluster embeddings are untouched. Replaces the artifact in place; we don't keep a backup
    /// of the raw transcript (per user preference: just keep the refined output, no toggle).
    /// Apple Intelligence was the original choice but doesn't yet support Czech; Qwen 2.5 / 3
    /// has solid CS support.
    func refineTranscript(for recording: Recording) {
        let id = recording.id
        let task = Task { @MainActor [weak self] in
            guard let self,
                  let initialRec = self.recordings.recordings.first(where: { $0.id == id }),
                  var artifact = self.recordings.loadArtifact(for: recording) else { return }
            // Auto-cleanup: clear the inflight slot + transient detail string when this task
            // body returns, success or fail.
            defer {
                self.inflightTasks[id] = nil
                self.cancellingIds.remove(id)
                self.processingDetail = nil
            }

            // Build a UUID → display-name map once. Used by the refiner to label speakers in
            // the prompt so the LLM understands turn-taking and which corrections fit which
            // person's vocabulary.
            var nameMap: [UUID: String] = [:]
            for (key, a) in artifact.clusterAssignments {
                guard let cid = Int(key) else { continue }
                if let sid = a.speakerId {
                    let live = speakers.speakers.first(where: { $0.id == sid })?.name
                    nameMap[sid] = live ?? a.displayName
                } else {
                    nameMap[UnnamedSpeakerID.make(clusterId: cid)] = a.displayName
                }
            }
            let nameFor: (UUID?) -> String = { sid in
                guard let sid else { return "Speaker" }
                return nameMap[sid] ?? "Speaker"
            }

            var rec = initialRec
            rec.status = .running(stage: .refining, progress: 0.0)
            recordings.upsert(rec, persistImmediately: true)

            let refiner = TranscriptRefiner()
            let recId = recording.id
            do {
                let refined = try await refiner.refine(
                    transcript: artifact.transcript,
                    speakerName: nameFor,
                    progress: { [weak self] progressStage in
                        // Map the refiner's typed stage onto the recording's processing-status
                        // stage so the progress banner can label download vs refining. Also
                        // computes a transient detail string ("X.X GB z Y.Y GB") for the
                        // download phase so the UI can render byte counts under the bar.
                        let stage: Recording.ProcessingStatus.Stage
                        let fraction: Double
                        let detail: String?
                        switch progressStage {
                        case .downloadingModel(let f, let cb, let tb):
                            stage = .downloadingModel
                            fraction = f
                            detail = Self.formatDownloadDetail(completed: cb, total: tb)
                        case .loadingModel:
                            stage = .loadingModel
                            fraction = 0
                            detail = nil
                        case .refining(let f):
                            stage = .refining
                            fraction = f
                            detail = nil
                        }
                        Task { @MainActor [weak self] in
                            guard let self,
                                  let idx = self.recordings.recordings.firstIndex(where: { $0.id == recId }) else { return }
                            var r = self.recordings.recordings[idx]
                            // The last progress(fraction: 1.0) is enqueued before refine() returns
                            // but runs AFTER the main flow has already set rec.status = .done. Without
                            // this guard, the stale task overwrites .done with .running(refining, 1.0)
                            // and the progress banner stays pinned at 100 % forever.
                            guard case .running = r.status else { return }
                            r.status = .running(stage: stage, progress: fraction)
                            self.recordings.upsert(r)
                            self.processingDetail = detail
                        }
                    }
                )
                artifact.transcript = refined
                recordings.saveArtifact(artifact, for: rec)
                rec.status = .done
                recordings.upsert(rec, persistImmediately: true)
            } catch is CancellationError {
                // User cancelled mid-refine: original artifact is still on disk and untouched
                // (we only persist on full success). Just revert the status — no error popup.
                rec.status = .done
                recordings.upsert(rec, persistImmediately: true)
                Log.app.info("refine cancelled by user")
            } catch {
                rec.status = .failed(message: error.localizedDescription)
                recordings.upsert(rec, persistImmediately: true)
                globalError = error.localizedDescription
            }
        }
        inflightTasks[id] = task
    }

    /// User renamed an unnamed speaker in a recording → promote to a named Speaker in DB,
    /// then re-stitch the artifact so segments point to the new speakerId.
    func promoteUnnamed(in recording: Recording, clusterId: Int, newName: String) {
        guard var artifact = recordings.loadArtifact(for: recording),
              let stored = artifact.assignment(for: clusterId) else { return }
        let normalized = newName.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return }

        let speakerId: UUID
        let displayName: String
        if let existing = speakers.speakers.first(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) {
            // Name already exists → treat as merge: add this cluster's embedding to the existing speaker.
            Log.app.info("promoteUnnamed: name \"\(normalized, privacy: .public)\" already exists, merging into existing speaker")
            if !stored.embedding.isEmpty {
                speakers.addSample(to: existing.id, embedding: stored.embedding)
            }
            speakerId = existing.id
            displayName = existing.name
        } else {
            let newSpeaker = speakers.create(name: normalized, embeddings: stored.embedding.isEmpty ? [] : [stored.embedding])
            speakerId = newSpeaker.id
            displayName = normalized
        }

        let unnamedId = UnnamedSpeakerID.make(clusterId: clusterId)
        var updated = stored
        updated.speakerId = speakerId
        updated.displayName = displayName
        artifact.setAssignment(updated, for: clusterId)

        for i in artifact.transcript.segments.indices {
            if artifact.transcript.segments[i].speakerId == unnamedId {
                artifact.transcript.segments[i].speakerId = speakerId
            }
        }
        recordings.saveArtifact(artifact, for: recording)
    }

    /// User renamed an already-known speaker.
    func renameKnown(speakerId: UUID, to newName: String) {
        speakers.rename(speakerId, to: newName)
    }

    /// Re-run identification on every currently-unnamed cluster in this recording.
    /// Useful after adding new samples to known speakers — old recordings can pick up matches retroactively.
    /// Doesn't touch clusters that are already assigned to a known speaker.
    func reidentifyUnnamed(in recording: Recording) -> Int {
        guard var artifact = recordings.loadArtifact(for: recording) else { return 0 }
        let unnamedClusters: [(clusterId: Int, embedding: [Float])] = artifact.clusterAssignments
            .compactMap { (key, a) in
                guard a.speakerId == nil, let cid = Int(key), !a.embedding.isEmpty else { return nil }
                return (cid, a.embedding)
            }
            .sorted { $0.clusterId < $1.clusterId }
        guard !unnamedClusters.isEmpty else { return 0 }

        let identifier = SpeakerIdentifier(store: speakers)
        let assignments = identifier.assign(clusters: unnamedClusters)

        var matched = 0
        for (cid, embedding) in unnamedClusters {
            guard case .known(let sid, let name, _) = assignments[cid] else { continue }
            let oldUnnamedId = UnnamedSpeakerID.make(clusterId: cid)
            artifact.setAssignment(StoredAssignment(speakerId: sid, displayName: name, embedding: embedding), for: cid)
            for i in artifact.transcript.segments.indices where artifact.transcript.segments[i].speakerId == oldUnnamedId {
                artifact.transcript.segments[i].speakerId = sid
            }
            matched += 1
        }
        recordings.saveArtifact(artifact, for: recording)
        return matched
    }

    /// Strip the named-speaker assignment from a cluster — segments revert to a fresh unnamed slot.
    /// The cluster's embedding stays so the user can re-name or re-match it.
    func unassignCluster(in recording: Recording, clusterId: Int) {
        guard var artifact = recordings.loadArtifact(for: recording),
              let stored = artifact.assignment(for: clusterId),
              let oldSpeakerId = stored.speakerId else { return }

        // Pick the next display index based on existing unnamed clusters in this recording.
        let nextIdx = (artifact.clusterAssignments.values.compactMap { a -> Int? in
            guard a.speakerId == nil, let n = Int(a.displayName.replacingOccurrences(of: "Speaker ", with: "")) else { return nil }
            return n
        }.max() ?? 0) + 1

        let newUnnamedId = UnnamedSpeakerID.make(clusterId: clusterId)
        artifact.setAssignment(
            StoredAssignment(speakerId: nil, displayName: "Speaker \(nextIdx)", embedding: stored.embedding),
            for: clusterId
        )
        for i in artifact.transcript.segments.indices where artifact.transcript.segments[i].speakerId == oldSpeakerId {
            artifact.transcript.segments[i].speakerId = newUnnamedId
        }
        recordings.saveArtifact(artifact, for: recording)
    }

    /// User added a sample to an existing speaker from a recording's cluster.
    func mergeCluster(in recording: Recording, clusterId: Int, into speakerId: UUID) {
        guard var artifact = recordings.loadArtifact(for: recording),
              let stored = artifact.assignment(for: clusterId) else { return }
        speakers.addSample(to: speakerId, embedding: stored.embedding)
        let name = speakers.speakers.first(where: { $0.id == speakerId })?.name ?? stored.displayName
        let oldId = stored.speakerId ?? UnnamedSpeakerID.make(clusterId: clusterId)
        artifact.setAssignment(StoredAssignment(speakerId: speakerId, displayName: name, embedding: stored.embedding), for: clusterId)
        for i in artifact.transcript.segments.indices {
            if artifact.transcript.segments[i].speakerId == oldId {
                artifact.transcript.segments[i].speakerId = speakerId
            }
        }
        recordings.saveArtifact(artifact, for: recording)
    }

}
