import XCTest
import TideCore
@testable import Tide

/// SyncActivityModel の reload / loadMore / フィルタの結合テスト（実 SQLite の temp DB に直 seed）。
/// ソースは `SyncActivitySource`（Issue #83）— DB ソース（folderSync）と FP イベントログソース
/// （fpOnly）の両方でモデル挙動を固定する。
@MainActor
final class SyncActivityModelTests: XCTestCase {
    private func makeDB() throws -> LocalDatabase {
        try makeTideTestEnv(prefix: "tide-activity-tests").db
    }

    private func makeSource() throws -> DatabaseActivitySource {
        DatabaseActivitySource(db: try makeDB())
    }

    // seedLogs は TestSupport.swift の XCTestCase 拡張へ集約（LocalDatabaseTests と共用）。

    func testReloadLoadsNewestFirstPage() async throws {
        let source = try makeSource()
        try await seedLogs(source.db, count: SyncActivityModel.pageSize + 5)

        let model = SyncActivityModel()
        await model.reload(source: source)

        XCTAssertEqual(model.entries.count, SyncActivityModel.pageSize)
        XCTAssertEqual(model.entries.first?.message, "m\(SyncActivityModel.pageSize + 4)", "新しい順")
        XCTAssertTrue(model.hasMore)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testLoadMoreAppendsWithoutDuplicates() async throws {
        let source = try makeSource()
        try await seedLogs(source.db, count: SyncActivityModel.pageSize + 3)

        let model = SyncActivityModel()
        await model.reload(source: source)
        await model.loadMore(source: source)

        XCTAssertEqual(model.entries.count, SyncActivityModel.pageSize + 3)
        XCTAssertFalse(model.hasMore)
        let ids = model.entries.compactMap(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "重複なし")
        XCTAssertEqual(model.entries.last?.message, "m0", "欠落なし（最古まで到達）")
    }

    func testFilterReloadsMatchingTypesOnly() async throws {
        let source = try makeSource()
        try await seedLogs(source.db, count: 6, types: [.upload, .error])

        let model = SyncActivityModel()
        // upload を外す → error のみ
        await model.toggleFilter(.upload, source: source)
        for type in SyncLogEventType.allCases where !(type == .upload || type == .error) {
            await model.toggleFilter(type, source: source)
        }

        XCTAssertEqual(model.entries.count, 3)
        XCTAssertTrue(model.entries.allSatisfy { $0.eventType == SyncLogEventType.error.rawValue })
    }

    func testEmptyDatabaseYieldsEmptyState() async throws {
        let source = try makeSource()
        let model = SyncActivityModel()
        await model.reload(source: source)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertFalse(model.isLoading)
    }

    func testLoadMoreWithoutEntriesIsNoop() async throws {
        let source = try makeSource()
        let model = SyncActivityModel()
        await model.loadMore(source: source)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testSelectionClearedWhenFilteredOut() async throws {
        let source = try makeSource()
        try await seedLogs(source.db, count: 4, types: [.upload, .error])

        let model = SyncActivityModel()
        await model.reload(source: source)
        // error 行（m3 or m1）を選択してから error を外す → 選択解除される。
        let errorEntry = model.entries.first { $0.eventType == SyncLogEventType.error.rawValue }
        model.selectedEntryId = errorEntry?.id
        XCTAssertNotNil(model.selectedEntry)

        await model.toggleFilter(.error, source: source)
        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.selectedEntryId)
    }

    // MARK: - FP イベントログソース（fpOnly・Issue #83）

    private func makeFPLog() throws -> FPEventLog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-activity-fp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return FPEventLog(bucket: "b", fileURL: dir.appendingPathComponent("events.jsonl"))
    }

    func testFPSourcePagesNewestFirstAcrossLoadMore() async throws {
        let log = try makeFPLog()
        for i in 0..<(SyncActivityModel.pageSize + 3) {
            await log.append(type: .upload, path: "f\(i).txt", message: "m\(i)")
        }
        let source = FPEventLogActivitySource(log: log)
        let model = SyncActivityModel()
        await model.reload(source: source)

        XCTAssertEqual(model.entries.count, SyncActivityModel.pageSize)
        XCTAssertEqual(model.entries.first?.message, "m\(SyncActivityModel.pageSize + 2)", "新しい順")
        XCTAssertTrue(model.hasMore)

        await model.loadMore(source: source)
        XCTAssertEqual(model.entries.count, SyncActivityModel.pageSize + 3)
        XCTAssertFalse(model.hasMore)
        let ids = model.entries.compactMap(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "重複なし")
        XCTAssertEqual(model.entries.last?.message, "m0", "欠落なし（最古まで到達）")
    }

    func testFPSourceFilterByEventType() async throws {
        let log = try makeFPLog()
        await log.append(type: .upload, path: "a.txt", message: "up")
        await log.append(type: .move, path: "a.txt", message: "Moved → b.txt")
        await log.append(type: .error, path: "b.txt", message: "boom")

        let source = FPEventLogActivitySource(log: log)
        let model = SyncActivityModel()
        model.selectedTypes = [.move]
        await model.reload(source: source)

        XCTAssertEqual(model.entries.map(\.message), ["Moved → b.txt"])
    }

    func testDBSourceKeepsSelectionAcrossReload() async throws {
        // DB は AUTOINCREMENT id が reload を跨いで安定 → 選択維持（従来挙動の固定）。
        let source = try makeSource()
        try await seedLogs(source.db, count: 3)
        let model = SyncActivityModel()
        await model.reload(source: source)
        model.selectedEntryId = model.entries.first?.id
        await model.reload(source: source)
        XCTAssertNotNil(model.selectedEntry)
    }

    func testFPSourceReloadClearsSelection() async throws {
        // FP の合成 id はローテーション世代破棄を跨ぐと前詰めされ別レコードを指しうる →
        // reload で無条件解除（PR #90 レビュー nit 2）。
        let log = try makeFPLog()
        await log.append(type: .upload, path: "a.txt", message: "m0")
        await log.append(type: .upload, path: "b.txt", message: "m1")
        let source = FPEventLogActivitySource(log: log)
        let model = SyncActivityModel()
        await model.reload(source: source)
        model.selectedEntryId = model.entries.first?.id
        XCTAssertNotNil(model.selectedEntry)

        await model.reload(source: source)
        XCTAssertNil(model.selectedEntryId)
        XCTAssertNil(model.selectedEntry)
    }

    func testDisplayedEventTypesPerSource() async throws {
        // folderSync は move を一次イベントとして持たない → Moves チップを出さない
        // （PR #90 レビュー nit 3）。FP は全種別。
        let dbSource = try makeSource()
        XCTAssertFalse(dbSource.displayedEventTypes.contains(.move))
        XCTAssertEqual(
            dbSource.displayedEventTypes,
            SyncLogEventType.allCases.filter { $0 != .move })

        let fpSource = FPEventLogActivitySource(log: try makeFPLog())
        XCTAssertEqual(fpSource.displayedEventTypes, SyncLogEventType.allCases)
    }

    func testFPSourceLoadMorePagesFromReloadSnapshot() async throws {
        // loadMore は reload 時スナップショットからページングする（読込の合間の追記で
        // カーソルがずれない）。追記後も reload するまでは古いスナップショットが正。
        let log = try makeFPLog()
        for i in 0..<(SyncActivityModel.pageSize + 1) {
            await log.append(type: .upload, path: "f\(i).txt", message: "m\(i)")
        }
        let source = FPEventLogActivitySource(log: log)
        let model = SyncActivityModel()
        await model.reload(source: source)
        XCTAssertTrue(model.hasMore)

        await log.append(type: .upload, path: "late.txt", message: "late")
        await model.loadMore(source: source)
        XCTAssertFalse(model.entries.contains { $0.message == "late" }, "追記は次の Refresh まで出ない")
        XCTAssertEqual(model.entries.count, SyncActivityModel.pageSize + 1)

        await model.reload(source: source)
        XCTAssertEqual(model.entries.first?.message, "late", "Refresh で追記が反映される")
    }
}
