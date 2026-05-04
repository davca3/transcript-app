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

        // Precompute centroids ONCE (otherwise computed property would re-sum the embeddings
        // for every (cluster × speaker) pair in the inner loop).
        struct SpeakerSnapshot { let id: UUID; let name: String; let centroid: [Float] }
        let snapshots: [SpeakerSnapshot] = store.speakers.map {
            SpeakerSnapshot(id: $0.id, name: $0.name, centroid: $0.centroid)
        }
        print("[SpeakerID] threshold=\(matchThreshold), clusters=\(clusters.count), known=\(snapshots.count)")

        // Per-cluster best-score (incl. below threshold), for tuning visibility.
        var bestPerCluster: [Int: (name: String, score: Float)] = [:]
        var pool = clusters
        while !pool.isEmpty {
            var best: (poolIdx: Int, speakerId: UUID, name: String, score: Float)?
            for (i, c) in pool.enumerated() {
                for s in snapshots where !usedSpeakerIds.contains(s.id) {
                    guard s.centroid.count == c.embedding.count else { continue }
                    let score = Cosine.similarity(c.embedding, s.centroid)
                    if let cur = bestPerCluster[c.clusterId], score <= cur.score {} else {
                        bestPerCluster[c.clusterId] = (s.name, score)
                    }
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
                // Log best per remaining cluster so the user sees how close they were.
                for c in pool {
                    if let bp = bestPerCluster[c.clusterId] {
                        print(String(format: "[SpeakerID] · cluster %d best: \"%@\" %.3f (below %.2f)",
                                     c.clusterId, bp.name, bp.score, matchThreshold))
                    }
                }
                break
            }
        }
        for c in pool {
            assignments[c.clusterId] = .unnamed(displayIndex: nextUnnamed, embedding: c.embedding)
            nextUnnamed += 1
        }
        return assignments
    }
}
