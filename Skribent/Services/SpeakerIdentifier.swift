import Foundation

/// Result of matching a per-recording cluster against the known-speaker DB.
enum SpeakerAssignment: Hashable {
    case known(speakerId: UUID, name: String, score: Float)
    case unnamed(displayIndex: Int, embedding: [Float])
}

@MainActor
final class SpeakerIdentifier {
    /// Cosine similarity threshold above which we consider a cluster a match.
    /// 0.55 works well for pyannote-style embeddings. Lower = more matches (more false positives),
    /// higher = stricter (more "Speaker N").
    var matchThreshold: Float = 0.55

    private let store: SpeakerStore

    init(store: SpeakerStore) {
        self.store = store
    }

    /// For each cluster (id → mean embedding), assign a known speaker or create an unnamed slot.
    func assign(clusters: [(clusterId: Int, embedding: [Float])]) -> [Int: SpeakerAssignment] {
        var assignments: [Int: SpeakerAssignment] = [:]
        var nextUnnamed = 1
        var usedSpeakerIds: Set<UUID> = []

        print("[SpeakerID] threshold=\(matchThreshold), clusters=\(clusters.count), known=\(store.speakers.count)")

        var pool = clusters
        while !pool.isEmpty {
            var best: (poolIdx: Int, speakerId: UUID, name: String, score: Float)?
            for (i, c) in pool.enumerated() {
                for s in store.speakers where !usedSpeakerIds.contains(s.id) {
                    // Skip stale profiles whose embedding dim doesn't match the current diarizer.
                    let centroid = s.centroid
                    guard centroid.count == c.embedding.count else {
                        print("[SpeakerID]   SKIP \"\(s.name)\" — dim mismatch (\(centroid.count) vs \(c.embedding.count)). Reset DB in Mluvčí.")
                        continue
                    }
                    let score = Cosine.similarity(c.embedding, centroid)
                    print(String(format: "[SpeakerID]   cluster %d vs \"%@\" → %.3f", c.clusterId, s.name, score))
                    if score >= matchThreshold, score > (best?.score ?? -1) {
                        best = (i, s.id, s.name, score)
                    }
                }
            }
            if let b = best {
                let cluster = pool.remove(at: b.poolIdx)
                print(String(format: "[SpeakerID] ✓ cluster %d → \"%@\" (score %.3f)", cluster.clusterId, b.name, b.score))
                assignments[cluster.clusterId] = .known(speakerId: b.speakerId, name: b.name, score: b.score)
                usedSpeakerIds.insert(b.speakerId)
            } else {
                break
            }
        }
        for c in pool {
            print("[SpeakerID] · cluster \(c.clusterId) → unnamed Speaker \(nextUnnamed)")
            assignments[c.clusterId] = .unnamed(displayIndex: nextUnnamed, embedding: c.embedding)
            nextUnnamed += 1
        }
        return assignments
    }
}
