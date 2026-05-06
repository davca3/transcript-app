import Foundation
import Combine

/// Stored per-recording sidecar — transcript + per-cluster embeddings + speaker assignments.
/// Cluster IDs are typed as `Int`; JSON serializes them as string-shaped keys (Foundation's
/// default for `[Int: V]`) so older artifacts that wrote `[String: StoredAssignment]` still
/// decode unchanged — same on-disk shape, stronger in-memory typing.
///
/// Schema-evolution policy: additive-only. New fields must be `Optional` or have a sensible
/// default (via custom `init(from:)`) so old artifacts on disk keep loading after an upgrade.
/// Renaming or retyping a field is a breaking change and needs a one-shot migration in `load()`.
struct RecordingArtifact: Codable, Hashable {
    var transcript: Transcript
    var clusterAssignments: [Int: StoredAssignment]

    init(transcript: Transcript, clusterAssignments: [Int: StoredAssignment]) {
        self.transcript = transcript
        self.clusterAssignments = clusterAssignments
    }

    /// Tolerant decode: missing `clusterAssignments` defaults to empty so an artifact written
    /// by a future build that drops the field (or by a partial write) still loads — the user
    /// sees segments without speaker chips instead of a blank failure banner.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.transcript = try c.decode(Transcript.self, forKey: .transcript)
        self.clusterAssignments = (try? c.decodeIfPresent([Int: StoredAssignment].self, forKey: .clusterAssignments)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case transcript, clusterAssignments
    }

    func assignment(for clusterId: Int) -> StoredAssignment? { clusterAssignments[clusterId] }
    mutating func setAssignment(_ a: StoredAssignment, for clusterId: Int) { clusterAssignments[clusterId] = a }

    /// Display-time mapping of clusterId → user-facing name. Two normalizations:
    /// - Named clusters use the live speaker name from the DB (so renames take effect immediately).
    /// - Unnamed clusters are renumbered sequentially (Speaker 1, 2, 3, ...) avoiding gaps left
    ///   by past unassigns/reidentifies (e.g. Speaker 5, 7, 8).
    func displayNames(knownSpeakers: [Speaker]) -> [Int: String] {
        let pairs = clusterAssignments.sorted { $0.key < $1.key }
        var out: [Int: String] = [:]
        var unnamedCounter = 1
        for (cid, a) in pairs {
            if let sid = a.speakerId, let live = knownSpeakers.first(where: { $0.id == sid }) {
                out[cid] = live.name
            } else if a.speakerId == nil {
                out[cid] = "Speaker \(unnamedCounter)"
                unnamedCounter += 1
            } else {
                out[cid] = a.displayName
            }
        }
        return out
    }
}

struct StoredAssignment: Codable, Hashable {
    var speakerId: UUID?     // nil = unnamed
    var displayName: String  // "Jana" or "Speaker 1"
    var embedding: [Float]
}

/// Lightweight per-recording snapshot used by the in-flight progress banner. Lives in its own
/// dictionary so 4 Hz pipeline updates don't churn the recordings array (avoiding re-renders of
/// the sidebar list, list rows, etc.).
struct ProcessingTick: Equatable {
    let stage: Recording.ProcessingStatus.Stage
    let progress: Double
}

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    /// In-memory artifact cache. Updated on every successful saveArtifact + invalidated on delete.
    /// Views observe this so renaming/promoting a speaker re-renders without forcing a global
    /// AppState publish. `loadArtifact` lazy-fills from disk on miss.
    @Published private(set) var artifactsByRecording: [UUID: RecordingArtifact] = [:]

    /// Latest non-fatal error from a load/save operation. AppState sinks this into globalError.
    @Published var lastError: Error?

    /// Per-recording in-flight progress snapshot driven by PipelineCoordinator. The whole entry
    /// is dropped at terminal status (.done / .failed). Decoupled from `recordings` so the 250 ms
    /// progress driver doesn't trigger a list-wide republish each tick.
    @Published var processingProgress: [UUID: ProcessingTick] = [:]

    nonisolated static var recordingsRoot: URL {
        let dir = AppPaths.appSupport.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var indexURL: URL { AppPaths.appSupport.appendingPathComponent("recordings.json") }
    private var saveDebounceTask: Task<Void, Never>?

    init() {
        load()
        cleanupOrphanedFolders()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            recordings = try JSONDecoder().decode([Recording].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            Log.store.error("RecordingStore load error: \(error.localizedDescription, privacy: .public)")
            lastError = error
        }
    }

    /// Delete recording folders that aren't referenced by any entry in the index. Runs once at
    /// startup to clean up after force-quits or partial-write crashes that leave audio.wav /
    /// transcript.json under a UUID directory the index never recorded.
    private func cleanupOrphanedFolders() {
        let root = Self.recordingsRoot
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let knownIds = Set(recordings.map(\.id.uuidString))
        var removed = 0
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, !knownIds.contains(entry.lastPathComponent) else { continue }
            // Defensive: only delete folders whose name parses as a UUID — never touch anything
            // a future feature might park under recordings/ for some other purpose.
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
            } catch {
                Log.store.notice("orphan cleanup failed for \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 {
            Log.store.info("cleaned up \(removed, privacy: .public) orphaned recording folder(s)")
        }
    }

    func save() {
        saveDebounceTask?.cancel(); saveDebounceTask = nil
        do {
            let data = try JSONEncoder().encode(recordings)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.store.error("RecordingStore save error: \(error.localizedDescription, privacy: .public)")
            lastError = error
        }
    }

    /// Debounced save (300ms). Coalesces rapid sequential upserts (e.g. pipeline stage updates)
    /// into a single disk write. Latest call wins. UI publish is unaffected.
    private func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.save()
        }
    }

    /// Insert or update a recording. By default the disk persist is debounced — pass
    /// `persistImmediately: true` for terminal states or new inserts where you want the index
    /// on disk immediately (crash recovery).
    func upsert(_ rec: Recording, persistImmediately: Bool = false) {
        if let idx = recordings.firstIndex(where: { $0.id == rec.id }) {
            recordings[idx] = rec
        } else {
            recordings.insert(rec, at: 0)
        }
        if persistImmediately { save() } else { scheduleSave() }
    }

    func delete(_ id: UUID) {
        delete(ids: [id])
    }

    /// Bulk delete: removes folders + index entries + cache entries for all ids, then writes the
    /// index once. Skips ids that aren't in `recordings` (e.g. already-deleted by a parallel
    /// path). Folder removal failures are logged + surfaced via `lastError` but don't abort the
    /// rest of the batch — the index is still rewritten so we don't leave a half-applied state.
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for r in recordings where ids.contains(r.id) {
            do {
                try FileManager.default.removeItem(at: r.folderURL)
            } catch CocoaError.fileNoSuchFile {
                // Already gone (manual cleanup, prior partial delete) — fine.
            } catch {
                Log.store.error("RecordingStore delete error: \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        recordings.removeAll { ids.contains($0.id) }
        for id in ids {
            artifactsByRecording[id] = nil
            processingProgress[id] = nil
        }
        save()
    }

    func loadArtifact(for rec: Recording) -> RecordingArtifact? {
        if let cached = artifactsByRecording[rec.id] { return cached }
        guard FileManager.default.fileExists(atPath: rec.transcriptURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: rec.transcriptURL)
            let artifact = try JSONDecoder().decode(RecordingArtifact.self, from: data)
            artifactsByRecording[rec.id] = artifact
            return artifact
        } catch {
            Log.store.error("loadArtifact error: \(error.localizedDescription, privacy: .public)")
            lastError = error
            return nil
        }
    }

    func saveArtifact(_ artifact: RecordingArtifact, for rec: Recording) {
        do {
            try FileManager.default.createDirectory(at: rec.folderURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(artifact)
            try data.write(to: rec.transcriptURL, options: .atomic)
            artifactsByRecording[rec.id] = artifact
        } catch {
            Log.store.error("saveArtifact error: \(error.localizedDescription, privacy: .public)")
            lastError = error
        }
    }
}
