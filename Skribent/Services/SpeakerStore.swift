import Foundation
import Combine

@MainActor
final class SpeakerStore: ObservableObject {
    @Published private(set) var speakers: [Speaker] = []
    /// Latest non-fatal error from a load/save operation. AppState sinks this into globalError so
    /// the UI can surface it. Auto-clears when set to nil by the consumer.
    @Published var lastError: Error?

    private let fileURL: URL

    init(fileURL: URL = SpeakerStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultURL: URL {
        let dir = AppPaths.appSupport
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speakers.json")
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            speakers = try JSONDecoder().decode([Speaker].self, from: data)
        } catch {
            Log.store.error("SpeakerStore load error: \(error.localizedDescription, privacy: .public)")
            lastError = error
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(speakers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.store.error("SpeakerStore save error: \(error.localizedDescription, privacy: .public)")
            lastError = error
        }
    }

    /// Create a new named speaker, seeded with one or more embeddings.
    @discardableResult
    func create(name: String, embeddings: [[Float]]) -> Speaker {
        let now = Date()
        let s = Speaker(id: UUID(), name: name, embeddings: embeddings, createdAt: now, updatedAt: now)
        speakers.append(s)
        save()
        return s
    }

    /// Append a new sample embedding to an existing speaker (cap at 8 samples — newest wins).
    /// If the new embedding's dim differs from existing samples, reset the speaker's samples to
    /// just this one — old samples come from a different (incompatible) model.
    func addSample(to speakerId: UUID, embedding: [Float]) {
        guard !embedding.isEmpty,
              let idx = speakers.firstIndex(where: { $0.id == speakerId }) else { return }
        var s = speakers[idx]
        if let firstDim = s.embeddings.first?.count, firstDim != embedding.count {
            Log.store.notice("dim mismatch on \"\(s.name, privacy: .public)\" (\(firstDim, privacy: .public) → \(embedding.count, privacy: .public)); resetting samples")
            s.embeddings = [embedding]
        } else {
            s.embeddings.append(embedding)
            if s.embeddings.count > 8 { s.embeddings.removeFirst(s.embeddings.count - 8) }
        }
        s.updatedAt = Date()
        speakers[idx] = s
        save()
    }

    func rename(_ speakerId: UUID, to newName: String) {
        guard let idx = speakers.firstIndex(where: { $0.id == speakerId }) else { return }
        speakers[idx].name = newName
        speakers[idx].updatedAt = Date()
        save()
    }

    func delete(_ speakerId: UUID) {
        speakers.removeAll { $0.id == speakerId }
        save()
    }
}
