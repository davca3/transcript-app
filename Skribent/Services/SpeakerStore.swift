import Foundation
import Combine

@MainActor
final class SpeakerStore: ObservableObject {
    @Published private(set) var speakers: [Speaker] = []

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
            print("SpeakerStore load error: \(error)")
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(speakers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("SpeakerStore save error: \(error)")
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
            print("[SpeakerStore] dim mismatch on \"\(s.name)\" (\(firstDim) → \(embedding.count)); resetting samples")
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

enum AppPaths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Skribent", isDirectory: true)
    }
}
