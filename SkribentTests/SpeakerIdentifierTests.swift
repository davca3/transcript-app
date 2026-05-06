import XCTest
@testable import Skribent

@MainActor
final class SpeakerIdentifierTests: XCTestCase {

    /// Builds a SpeakerStore that persists to a unique tmp file (so tests can't pollute the
    /// real app DB and can run in parallel).
    private func makeIsolatedStore() -> SpeakerStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("skribent-test-\(UUID().uuidString).json")
        return SpeakerStore(fileURL: tmp)
    }

    private func unitVector(_ axis: Int, dim: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = 1
        return v
    }

    func test_assign_emptyKnownSpeakers_allClustersUnnamed() {
        let store = makeIsolatedStore()
        let identifier = SpeakerIdentifier(store: store)
        let clusters: [(clusterId: Int, embedding: [Float])] = [
            (1, unitVector(0)),
            (2, unitVector(1)),
        ]
        let assignments = identifier.assign(clusters: clusters)
        XCTAssertEqual(assignments.count, 2)
        for (_, a) in assignments {
            if case .unnamed = a { } else { XCTFail("expected unnamed, got \(a)") }
        }
    }

    func test_assign_strongMatch_picksKnownSpeaker() {
        let store = makeIsolatedStore()
        store.create(name: "Jana", embeddings: [unitVector(0)])
        let identifier = SpeakerIdentifier(store: store)

        let assignments = identifier.assign(clusters: [(1, unitVector(0))])
        guard case .known(_, let name, let score) = assignments[1] else {
            return XCTFail("expected known assignment, got \(String(describing: assignments[1]))")
        }
        XCTAssertEqual(name, "Jana")
        XCTAssertGreaterThan(score, 0.99)
    }

    func test_assign_weakMatch_fallsBackToUnnamed() {
        let store = makeIsolatedStore()
        store.create(name: "Jana", embeddings: [unitVector(0)])
        let identifier = SpeakerIdentifier(store: store)
        identifier.matchThreshold = 0.99  // make match nearly impossible

        let almost = unitVector(0)  // identical = score 1.0; orthogonal would not match
        let orthogonal = unitVector(1)
        let assignments = identifier.assign(clusters: [(1, orthogonal), (2, almost)])

        if case .unnamed = assignments[1] { } else { XCTFail("expected unnamed for orthogonal cluster") }
        // The identical-to-Jana cluster should still match (score = 1.0 ≥ threshold 0.99).
        if case .known = assignments[2] { } else { XCTFail("expected known for matching cluster") }
    }

    func test_assign_dimensionMismatch_skipsSpeaker() {
        let store = makeIsolatedStore()
        store.create(name: "Jana", embeddings: [[Float](repeating: 0.5, count: 4)])
        let identifier = SpeakerIdentifier(store: store)

        // Cluster has different dim — speaker should be skipped, cluster lands as unnamed.
        let assignments = identifier.assign(clusters: [(1, unitVector(0, dim: 8))])
        if case .unnamed = assignments[1] { } else { XCTFail("dim mismatch should fall back to unnamed") }
    }

    func test_assign_multiCluster_eachKnownSpeakerUsedOnce() {
        let store = makeIsolatedStore()
        store.create(name: "Jana", embeddings: [unitVector(0)])
        store.create(name: "Petr", embeddings: [unitVector(1)])
        let identifier = SpeakerIdentifier(store: store)

        // Two clusters — one matches Jana, one matches Petr. Greedy pool removal must
        // assign each known speaker to exactly one cluster.
        let assignments = identifier.assign(clusters: [(1, unitVector(0)), (2, unitVector(1))])
        var pickedNames: Set<String> = []
        for (_, a) in assignments {
            guard case .known(_, let name, _) = a else { continue }
            pickedNames.insert(name)
        }
        XCTAssertEqual(pickedNames, ["Jana", "Petr"])
    }
}
