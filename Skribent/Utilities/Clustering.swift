import Foundation

/// Single-link agglomerative clustering on cosine similarity. Used as a
/// fallback when the diarizer returns raw embeddings without cluster IDs.
enum Clustering {
    /// Returns cluster id per input (0-indexed). `threshold` is min cosine similarity to merge.
    static func agglomerative(_ embeddings: [[Float]], threshold: Float = 0.7) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                if Cosine.similarity(embeddings[i], embeddings[j]) >= threshold {
                    let ri = find(i), rj = find(j)
                    if ri != rj { parent[ri] = rj }
                }
            }
        }
        var idMap: [Int: Int] = [:]
        var next = 0
        return (0..<n).map { i in
            let root = find(i)
            if let id = idMap[root] { return id }
            idMap[root] = next; defer { next += 1 }
            return next
        }
    }
}
