import XCTest
@testable import Skribent

@MainActor
final class RecordingStoreTests: XCTestCase {

    /// Build a store and seed it with N recordings whose folders also exist on disk, so we can
    /// verify both the index *and* the filesystem after delete operations.
    private func makeStoreWithRecordings(count: Int) -> (RecordingStore, [Recording]) {
        let store = RecordingStore()
        var created: [Recording] = []
        for i in 0..<count {
            let rec = Recording(
                id: UUID(),
                title: "Test \(i)",
                createdAt: Date().addingTimeInterval(TimeInterval(i)),
                duration: 60,
                sourceKind: .imported,
                status: .done
            )
            // Create the folder on disk so the bulk-delete path actually has something to remove.
            try? FileManager.default.createDirectory(at: rec.folderURL, withIntermediateDirectories: true)
            store.upsert(rec, persistImmediately: true)
            created.append(rec)
        }
        return (store, created)
    }

    private func cleanup(_ store: RecordingStore) {
        store.delete(ids: Set(store.recordings.map(\.id)))
    }

    func test_bulkDelete_removesFromIndexAndFilesystem() {
        let (store, recs) = makeStoreWithRecordings(count: 3)
        defer { cleanup(store) }
        XCTAssertEqual(store.recordings.count, 3)

        let toDelete: Set<UUID> = [recs[0].id, recs[2].id]
        store.delete(ids: toDelete)

        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.id, recs[1].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recs[0].folderURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recs[2].folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recs[1].folderURL.path))
    }

    func test_bulkDelete_emptyInput_isNoOp() {
        let (store, _) = makeStoreWithRecordings(count: 2)
        defer { cleanup(store) }
        let originalCount = store.recordings.count
        store.delete(ids: [])
        XCTAssertEqual(store.recordings.count, originalCount)
    }

    func test_bulkDelete_unknownIds_skipsSilently() {
        let (store, recs) = makeStoreWithRecordings(count: 1)
        defer { cleanup(store) }
        // Mix of one real id and two random ids that aren't in the store.
        let toDelete: Set<UUID> = [recs[0].id, UUID(), UUID()]
        store.delete(ids: toDelete)
        XCTAssertEqual(store.recordings.count, 0)
    }

    func test_renameRecording_updatesTitle() async {
        let (store, recs) = makeStoreWithRecordings(count: 1)
        defer { cleanup(store) }
        let state = AppState(recordings: store, autoPreload: false)
        state.renameRecording(recs[0].id, to: "  Nový název  ")
        XCTAssertEqual(state.recordings.recordings.first?.title, "Nový název", "should trim whitespace")
    }

    func test_renameRecording_emptyName_isNoOp() async {
        let (store, recs) = makeStoreWithRecordings(count: 1)
        defer { cleanup(store) }
        let state = AppState(recordings: store, autoPreload: false)
        let original = recs[0].title
        state.renameRecording(recs[0].id, to: "   ")
        XCTAssertEqual(state.recordings.recordings.first?.title, original)
    }

    func test_renameRecording_unknownId_isNoOp() async {
        let (store, _) = makeStoreWithRecordings(count: 1)
        defer { cleanup(store) }
        let state = AppState(recordings: store, autoPreload: false)
        let snapshot = state.recordings.recordings
        state.renameRecording(UUID(), to: "Foo")
        XCTAssertEqual(state.recordings.recordings, snapshot)
    }
}
