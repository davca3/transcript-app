import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    let speakers = SpeakerStore()
    let recordings = RecordingStore()
    let recorder = AudioRecorder()

    @Published var selectedRecordingId: UUID?
    @Published var globalError: String?

    let pipeline: PipelineCoordinator
    let transcriber: WhisperKitTranscriber
    #if canImport(FluidAudio)
    let diarizer: FluidAudioDiarizer
    #endif

    private var cancellables = Set<AnyCancellable>()

    init() {
        let transcriber = WhisperKitTranscriber()
        self.transcriber = transcriber

        let diarizationService: DiarizationService
        let embeddingService: SpeakerEmbeddingService
        #if canImport(FluidAudio)
        let fluid = FluidAudioDiarizer()
        self.diarizer = fluid
        diarizationService = fluid
        embeddingService = fluid
        #else
        let stub = StubDiarizer()
        diarizationService = stub
        embeddingService = stub
        #endif

        let identifier = SpeakerIdentifier(store: speakers)
        self.pipeline = PipelineCoordinator(
            transcriber: transcriber,
            diarizer: diarizationService,
            embedder: embeddingService,
            identifier: identifier,
            recordings: recordings,
            speakers: speakers
        )

        // Forward inner stores' changes to AppState's publisher so views observing AppState
        // refresh when recordings/speakers change (e.g., during regenerate).
        recordings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        speakers.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Warm up models in parallel so first recording is instant.
        Task { await transcriber.preload() }
        #if canImport(FluidAudio)
        Task { await fluid.preload() }
        #endif
    }

    func processNewRecording(sourceURL: URL, title: String, kind: Recording.SourceKind) {
        Task {
            await pipeline.process(sourceURL: sourceURL, title: title, sourceKind: kind) { [weak self] rec in
                Task { @MainActor in
                    self?.selectedRecordingId = rec.id
                }
            }
        }
    }

    func regenerateTranscript(for recording: Recording) {
        Task {
            await pipeline.reprocess(recording) { _ in }
        }
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
            print("[AppState] promoteUnnamed: name \"\(normalized)\" already exists, merging into existing speaker")
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
        objectWillChange.send()
    }

    /// User renamed an already-known speaker.
    func renameKnown(speakerId: UUID, to newName: String) {
        speakers.rename(speakerId, to: newName)
        objectWillChange.send()
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
        objectWillChange.send()
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
        objectWillChange.send()
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
        objectWillChange.send()
    }

}
