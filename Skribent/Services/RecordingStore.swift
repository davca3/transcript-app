import Foundation
import Combine

/// Stored per-recording sidecar — transcript + per-cluster embeddings + speaker assignments.
/// Cluster IDs are kept as strings so the JSON payload is human-readable.
struct RecordingArtifact: Codable, Hashable {
    var transcript: Transcript
    var clusterAssignments: [String: StoredAssignment]

    func assignment(for clusterId: Int) -> StoredAssignment? { clusterAssignments[String(clusterId)] }
    mutating func setAssignment(_ a: StoredAssignment, for clusterId: Int) { clusterAssignments[String(clusterId)] = a }

    /// Display-time mapping of clusterId → user-facing name. Two normalizations:
    /// - Named clusters use the live speaker name from the DB (so renames take effect immediately).
    /// - Unnamed clusters are renumbered sequentially (Speaker 1, 2, 3, ...) avoiding gaps left
    ///   by past unassigns/reidentifies (e.g. Speaker 5, 7, 8).
    func displayNames(knownSpeakers: [Speaker]) -> [Int: String] {
        let pairs = clusterAssignments
            .compactMap { (k, v) -> (Int, StoredAssignment)? in Int(k).map { ($0, v) } }
            .sorted { $0.0 < $1.0 }
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

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    nonisolated static var recordingsRoot: URL {
        let dir = AppPaths.appSupport.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var indexURL: URL { AppPaths.appSupport.appendingPathComponent("recordings.json") }
    private var saveDebounceTask: Task<Void, Never>?

    init() { load() }

    func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            recordings = try JSONDecoder().decode([Recording].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            print("RecordingStore load error: \(error)")
        }
    }

    func save() {
        saveDebounceTask?.cancel(); saveDebounceTask = nil
        do {
            let data = try JSONEncoder().encode(recordings)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("RecordingStore save error: \(error)")
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
        if let r = recordings.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: r.folderURL)
        }
        recordings.removeAll { $0.id == id }
        save()
    }

    func loadArtifact(for rec: Recording) -> RecordingArtifact? {
        guard FileManager.default.fileExists(atPath: rec.transcriptURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: rec.transcriptURL)
            return try JSONDecoder().decode(RecordingArtifact.self, from: data)
        } catch {
            print("loadArtifact error: \(error)")
            return nil
        }
    }

    func saveArtifact(_ artifact: RecordingArtifact, for rec: Recording) {
        do {
            try FileManager.default.createDirectory(at: rec.folderURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(artifact)
            try data.write(to: rec.transcriptURL, options: .atomic)
        } catch {
            print("saveArtifact error: \(error)")
        }
    }
}
