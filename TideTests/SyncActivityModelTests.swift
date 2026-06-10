import XCTest
@testable import Tide

/// SyncActivityModel の reload / loadMore / フィルタの結合テスト（実 SQLite の temp DB に直 seed）。
@MainActor
final class SyncActivityModelTests: XCTestCase {
    private func makeDB() throws -> LocalDatabase {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-activity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return try LocalDatabase(at: base.appendingPathComponent("db.sqlite"))
    }

    private func seedLogs(_ db: LocalDatabase, count: Int, types: [SyncLogEventType] = [.upload]) async throws {
        try await db.pool.write { dbq in
            for i in 0..<count {
                var row = SyncLogRecord(
                    id: nil,
                    timestamp: 1000.0 + Double(i),
                    eventType: types[i % types.count].rawValue,
                    path: "f\(i).txt",
                    message: "m\(i)",
                    details: nil
                )
                try row.insert(dbq)
            }
        }
    }

    func testReloadLoadsNewestFirstPage() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: SyncActivityModel.pageSize + 5)

        let model = SyncActivityModel()
        await model.reload(db: db)

        XCTAssertEqual(model.entries.count, SyncActivityModel.pageSize)
        XCTAssertEqual(model.entries.first?.message, "m\(SyncActivityModel.pageSize + 4)", "新しい順")
        XCTAssertTrue(model.hasMore)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testLoadMoreAppendsWithoutDuplicates() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: SyncActivityModel.pageSize + 3)

        let model = SyncActivityModel()
        await model.reload(db: db)
        await model.loadMore(db: db)

        XCTAssertEqual(model.entries.count, SyncActivityModel.pageSize + 3)
        XCTAssertFalse(model.hasMore)
        let ids = model.entries.compactMap(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "重複なし")
        XCTAssertEqual(model.entries.last?.message, "m0", "欠落なし（最古まで到達）")
    }

    func testFilterReloadsMatchingTypesOnly() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: 6, types: [.upload, .error])

        let model = SyncActivityModel()
        // upload を外す → error のみ
        await model.toggleFilter(.upload, db: db)
        for type in SyncLogEventType.allCases where !(type == .upload || type == .error) {
            await model.toggleFilter(type, db: db)
        }

        XCTAssertEqual(model.entries.count, 3)
        XCTAssertTrue(model.entries.allSatisfy { $0.eventType == SyncLogEventType.error.rawValue })
    }

    func testEmptyDatabaseYieldsEmptyState() async throws {
        let db = try makeDB()
        let model = SyncActivityModel()
        await model.reload(db: db)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertFalse(model.isLoading)
    }

    func testLoadMoreWithoutEntriesIsNoop() async throws {
        let db = try makeDB()
        let model = SyncActivityModel()
        await model.loadMore(db: db)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testSelectionClearedWhenFilteredOut() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: 4, types: [.upload, .error])

        let model = SyncActivityModel()
        await model.reload(db: db)
        // error 行（m3 or m1）を選択してから error を外す → 選択解除される。
        let errorEntry = model.entries.first { $0.eventType == SyncLogEventType.error.rawValue }
        model.selectedEntryId = errorEntry?.id
        XCTAssertNotNil(model.selectedEntry)

        await model.toggleFilter(.error, db: db)
        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.selectedEntryId)
    }
}
