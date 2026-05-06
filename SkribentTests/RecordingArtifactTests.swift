import XCTest
@testable import Skribent

final class RecordingArtifactTests: XCTestCase {

    private func makeArtifact(_ assignments: [(Int, StoredAssignment)]) -> RecordingArtifact {
        var dict: [String: StoredAssignment] = [:]
        for (cid, a) in assignments { dict[String(cid)] = a }
        return RecordingArtifact(transcript: Transcript(segments: [], detectedLanguage: nil),
                                 clusterAssignments: dict)
    }

    func test_displayNames_namedClusterUsesLiveSpeakerName() {
        let janaId = UUID()
        let jana = Speaker(id: janaId, name: "Jana", embeddings: [], createdAt: Date(), updatedAt: Date())
        let artifact = makeArtifact([
            (1, StoredAssignment(speakerId: janaId, displayName: "stale-old-name", embedding: [])),
        ])
        let names = artifact.displayNames(knownSpeakers: [jana])
        XCTAssertEqual(names[1], "Jana", "should pick live name from DB, not stored displayName")
    }

    func test_displayNames_namedClusterWithDeletedSpeaker_fallsBackToDisplayName() {
        let ghostId = UUID()
        let artifact = makeArtifact([
            (1, StoredAssignment(speakerId: ghostId, displayName: "Petr", embedding: [])),
        ])
        // No matching speaker in knownSpeakers — should fall back to the stored displayName.
        let names = artifact.displayNames(knownSpeakers: [])
        XCTAssertEqual(names[1], "Petr")
    }

    func test_displayNames_unnamedClustersRenumberedSequentially() {
        // Cluster IDs 5, 7, 8 (gaps) — display labels should be Speaker 1/2/3 in cluster order.
        let artifact = makeArtifact([
            (5, StoredAssignment(speakerId: nil, displayName: "Speaker 5", embedding: [])),
            (7, StoredAssignment(speakerId: nil, displayName: "Speaker 7", embedding: [])),
            (8, StoredAssignment(speakerId: nil, displayName: "Speaker 8", embedding: [])),
        ])
        let names = artifact.displayNames(knownSpeakers: [])
        XCTAssertEqual(names[5], "Speaker 1")
        XCTAssertEqual(names[7], "Speaker 2")
        XCTAssertEqual(names[8], "Speaker 3")
    }

    func test_displayNames_mixedNamedAndUnnamed_keepsLiveNamesAndRenumbersUnnamedOnly() {
        let janaId = UUID()
        let jana = Speaker(id: janaId, name: "Jana", embeddings: [], createdAt: Date(), updatedAt: Date())
        let artifact = makeArtifact([
            (1, StoredAssignment(speakerId: nil, displayName: "Speaker 5", embedding: [])),
            (2, StoredAssignment(speakerId: janaId, displayName: "Jana", embedding: [])),
            (3, StoredAssignment(speakerId: nil, displayName: "Speaker 7", embedding: [])),
        ])
        let names = artifact.displayNames(knownSpeakers: [jana])
        XCTAssertEqual(names[1], "Speaker 1")
        XCTAssertEqual(names[2], "Jana")
        XCTAssertEqual(names[3], "Speaker 2")
    }
}
