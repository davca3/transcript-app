import XCTest
@testable import Skribent

final class ClusteringTests: XCTestCase {
    func test_emptyInput_returnsEmpty() {
        XCTAssertEqual(Clustering.agglomerative([]), [])
    }

    func test_singleEmbedding_returnsSingleClusterId() {
        let result = Clustering.agglomerative([[1, 0, 0]])
        XCTAssertEqual(result, [0])
    }

    func test_threeIdenticalEmbeddings_collapseToSingleCluster() {
        let v: [Float] = [1, 0, 0]
        let result = Clustering.agglomerative([v, v, v], threshold: 0.7)
        XCTAssertEqual(result, [0, 0, 0])
    }

    func test_threeDisjointEmbeddings_returnDistinctClusters() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let c: [Float] = [0, 0, 1]
        let result = Clustering.agglomerative([a, b, c], threshold: 0.7)
        XCTAssertEqual(Set(result).count, 3)
    }

    func test_singleLinkTransitivity_mergesViaIntermediate() {
        // A is similar to B, B similar to C, but A not directly similar to C.
        // Single-link agglomerative should merge all three via the chain.
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.71, 0.71, 0.0]
        let c: [Float] = [0.0, 1.0, 0.0]
        let result = Clustering.agglomerative([a, b, c], threshold: 0.7)
        XCTAssertEqual(Set(result).count, 1, "transitive single-link merge failed: \(result)")
    }

    func test_clusterIdsAreCompactlyAssigned() {
        // Two clusters with distinct embeddings; ids should be 0 and 1, no gaps.
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        let result = Clustering.agglomerative([a, a, b, b, a], threshold: 0.7)
        XCTAssertTrue(Set(result).isSubset(of: [0, 1]))
        XCTAssertEqual(result.first, 0, "first input should always get cluster 0")
    }
}
