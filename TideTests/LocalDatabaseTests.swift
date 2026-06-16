import XCTest
@testable import Tide

/// `LocalDatabase.refreshMtimeIfShaUnchanged`（SHA ゲートの CAS 更新）の回帰テスト。
/// 判定（read → hash）と書込の間に並行 pull が同 path を更新した場合に、
/// 新しい sha / s3VersionId / s3Etag を巻き戻さないことを固定する。
final class LocalDatabaseTests: XCTestCase {
    private func makeDB() throws -> LocalDatabase {
        try makeTideTestEnv(prefix: "tide-db-tests").db
    }

    private func seed(
        _ db: LocalDatabase, path: String, mtime: Double, sha: String,
        versionId: String? = "v1", lastSyncedAt: Double? = 1_780_000_000
    ) async throws {
        try await db.pool.write { dbq in
            var rec = FileRecord(
                path: path, size: 100, mtime: mtime, sha256: sha,
                s3VersionId: versionId, s3Etag: "e1",
                lastSyncedAt: lastSyncedAt, updatedAt: 1_780_000_000
            )
            try rec.save(dbq)
        }
    }

    private func fetch(_ db: LocalDatabase, _ path: String) async throws -> FileRecord? {
        try await db.pool.read { dbq in try FileRecord.fetchOne(dbq, key: path) }
    }

    func testRefreshUpdatesMtimeAndPreservesEverythingElse() async throws {
        let db = try makeDB()
        try await seed(db, path: "a.bin", mtime: 1_780_000_000.0, sha: "abc")

        let updated = try await db.refreshMtimeIfShaUnchanged(
            path: "a.bin", expectedSha: "abc", newMtime: 1_780_000_000.789
        )

        XCTAssertTrue(updated)
        let fetched = try await fetch(db, "a.bin")
        let rec = try XCTUnwrap(fetched)
        XCTAssertEqual(rec.mtime, 1_780_000_000.789, accuracy: 0.0001)
        XCTAssertEqual(rec.sha256, "abc")
        XCTAssertEqual(rec.s3VersionId, "v1", "sha/versionId は触らない")
        XCTAssertEqual(rec.lastSyncedAt, 1_780_000_000, "lastSyncedAt を保持（tracked 判定が崩れない）")
    }

    func testRefreshIsNoopWhenShaChangedConcurrently() async throws {
        let db = try makeDB()
        // 判定時 sha = "abc" → 書込前に並行 pull が新内容（sha = "new", v2, 新 mtime）で更新した状況。
        try await seed(db, path: "a.bin", mtime: 1_790_000_000.0, sha: "new", versionId: "v2")

        let updated = try await db.refreshMtimeIfShaUnchanged(
            path: "a.bin", expectedSha: "abc", newMtime: 1_780_000_000.789
        )

        XCTAssertFalse(updated, "sha 不一致なら no-op（並行更新を巻き戻さない）")
        let fetched = try await fetch(db, "a.bin")
        let rec = try XCTUnwrap(fetched)
        XCTAssertEqual(rec.mtime, 1_790_000_000.0, accuracy: 0.0001)
        XCTAssertEqual(rec.sha256, "new")
        XCTAssertEqual(rec.s3VersionId, "v2")
    }

    func testRefreshIsNoopWhenRowMissing() async throws {
        let db = try makeDB()
        let updated = try await db.refreshMtimeIfShaUnchanged(
            path: "ghost.bin", expectedSha: "abc", newMtime: 1
        )
        XCTAssertFalse(updated)
    }

    // MARK: - L6: upload_queue 行の id 基準ライフサイクル（in-flight collapse 回帰）

    @discardableResult
    private func enqueueUpload(
        _ db: LocalDatabase, path: String,
        attempts: Int = 0, enqueuedAt: Double = 1_780_000_000
    ) async throws -> Int64 {
        try await db.pool.write { dbq in
            var rec = UploadQueueRecord(
                id: nil, path: path, operation: "upload",
                enqueuedAt: enqueuedAt, attempts: attempts, nextRetryAt: nil, lastError: nil
            )
            try rec.insert(dbq, onConflict: .replace)
            return rec.id!
        }
    }

    /// アップロード処理中に同 path へ新イベントが届くと INSERT OR REPLACE で新 id 行に置換される。
    /// 完了時の削除を path ではなく **id 基準**で行えば、その新行（＝完全版の再アップロード指示）が残り、
    /// 次周回で再処理される。path 基準だと新行まで巻き込み消去し、ローカル≠DB≠リモートの
    /// 無エラー乖離になっていた（L6）。ここでは REPLACE が新 id を振ること＋ id 基準削除が新行を
    /// 残すことを固定する。
    func testDeleteByIdPreservesRowReplacedDuringProcessing() async throws {
        let db = try makeDB()

        // R1: in-flight としてフェッチ済みのつもりの行。
        let id1 = try await enqueueUpload(db, path: "big.bin")
        // 書込完了イベント → INSERT OR REPLACE で R2（新 id）へ置換。
        let id2 = try await enqueueUpload(db, path: "big.bin")
        XCTAssertNotEqual(id1, id2, "INSERT OR REPLACE は新しい AUTOINCREMENT id を振る")

        // 完了処理：処理した行 id1 だけを削除（production の filter(id == item.id) 相当）。
        let deleted = try await db.pool.write { dbq in
            try UploadQueueRecord.deleteOne(dbq, key: id1)
        }
        XCTAssertFalse(deleted, "id1 は既に REPLACE で消えている → 削除対象なし（新行を巻き込まない）")

        let r1 = try await db.pool.read { dbq in try UploadQueueRecord.fetchOne(dbq, key: id1) }
        let r2 = try await db.pool.read { dbq in try UploadQueueRecord.fetchOne(dbq, key: id2) }
        let total = try await db.pool.read { dbq in try UploadQueueRecord.fetchCount(dbq) }
        XCTAssertNil(r1)
        XCTAssertEqual(r2?.path, "big.bin", "id 基準なら置換後の新行が残る")
        XCTAssertEqual(total, 1)
    }

    /// 削除（id1）が先・再 enqueue（R2）が後の順序でも、id 基準なら R2 は消えない。
    func testDeleteByIdBeforeReplacePreservesNewRow() async throws {
        let db = try makeDB()
        let id1 = try await enqueueUpload(db, path: "big.bin")
        _ = try await db.pool.write { dbq in try UploadQueueRecord.deleteOne(dbq, key: id1) }
        let id2 = try await enqueueUpload(db, path: "big.bin")

        let total = try await db.pool.read { dbq in try UploadQueueRecord.fetchCount(dbq) }
        let r2 = try await db.pool.read { dbq in try UploadQueueRecord.fetchOne(dbq, key: id2) }
        XCTAssertEqual(total, 1)
        XCTAssertEqual(r2?.path, "big.bin")
    }

    // MARK: - L6 (3/3): 不安定ファイルの延期（deferUnstableQueueItem）

    /// 延期は give-up カウント（attempts）と enqueuedAt を保持し、nextRetryAt だけ前進させる。
    func testDeferUnstableKeepsAttemptsAndEnqueuedAt() async throws {
        let db = try makeDB()
        let id = try await enqueueUpload(db, path: "log.bin", attempts: 3, enqueuedAt: 1000)

        let ok = try await db.deferUnstableQueueItem(id: id, nextRetryAt: 1234, lastError: "changing")
        XCTAssertTrue(ok)

        let row = try await db.pool.read { dbq in try UploadQueueRecord.fetchOne(dbq, key: id) }
        XCTAssertEqual(row?.attempts, 3, "give-up カウントに載せない＝attempts 不変")
        XCTAssertEqual(row?.nextRetryAt, 1234.0)
        XCTAssertEqual(row?.enqueuedAt, 1000.0, "enqueuedAt 据え置き（保留経過の基準）")
    }

    /// 処理中に置換された（新 id の）行には触れない（no-op で false を返す）。
    func testDeferUnstableNoopWhenRowReplaced() async throws {
        let db = try makeDB()
        let id1 = try await enqueueUpload(db, path: "log.bin")
        _ = try await enqueueUpload(db, path: "log.bin")    // REPLACE → 新 id、id1 は消える

        let ok = try await db.deferUnstableQueueItem(id: id1, nextRetryAt: 1234, lastError: "x")
        XCTAssertFalse(ok, "置換済み行（id1 不在）には触れない")
    }

    // MARK: - sync_log の読出（fetchLogs・Sync Activity 用）

    // seedLogs は TestSupport.swift の XCTestCase 拡張へ集約（SyncActivityModelTests と共用）。

    func testFetchLogsReturnsNewestFirst() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: 5)

        let page = try await db.fetchLogs(limit: 10)
        XCTAssertEqual(page.records.map(\.message), ["m4", "m3", "m2", "m1", "m0"])
        XCTAssertFalse(page.hasMore)
    }

    func testFetchLogsFiltersByEventType() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: 6, types: [.upload, .error, .info])

        let errors = try await db.fetchLogs(eventTypes: [.error], limit: 10)
        XCTAssertEqual(errors.records.map(\.eventType), ["error", "error"])

        let two = try await db.fetchLogs(eventTypes: [.error, .info], limit: 10)
        XCTAssertEqual(two.records.count, 4)

        // 空集合は「全種別」ではなく 0 件（nil とは区別する）。
        let none = try await db.fetchLogs(eventTypes: [], limit: 10)
        XCTAssertTrue(none.records.isEmpty)
        XCTAssertFalse(none.hasMore)
    }

    /// beforeId カーソルで 2 ページ目が重複も欠落もなく続く。
    func testFetchLogsPaginatesWithBeforeIdCursor() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: 7)

        let first = try await db.fetchLogs(limit: 3)
        XCTAssertEqual(first.records.count, 3)
        XCTAssertTrue(first.hasMore)

        let second = try await db.fetchLogs(beforeId: first.records.last?.id, limit: 3)
        XCTAssertEqual(second.records.count, 3)
        XCTAssertTrue(second.hasMore)

        let third = try await db.fetchLogs(beforeId: second.records.last?.id, limit: 3)
        XCTAssertEqual(third.records.count, 1)
        XCTAssertFalse(third.hasMore)

        let all = (first.records + second.records + third.records).map(\.message)
        XCTAssertEqual(all, ["m6", "m5", "m4", "m3", "m2", "m1", "m0"], "重複・欠落なし")
    }

    /// hasMore の境界: ちょうど limit 件なら false、limit+1 件なら true。
    func testFetchLogsHasMoreBoundary() async throws {
        let db = try makeDB()
        try await seedLogs(db, count: 3)

        let exact = try await db.fetchLogs(limit: 3)
        XCTAssertEqual(exact.records.count, 3)
        XCTAssertFalse(exact.hasMore)

        try await seedLogs(db, count: 1)
        let over = try await db.fetchLogs(limit: 3)
        XCTAssertEqual(over.records.count, 3)
        XCTAssertTrue(over.hasMore)
    }

    func testAppendLogWritesRow() async throws {
        let db = try makeDB()
        try await db.appendLog(type: .error, path: "a.txt", message: "Remote pull failed", details: "raw detail")

        let page = try await db.fetchLogs(eventTypes: [.error], limit: 10)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(page.records.first?.path, "a.txt")
        XCTAssertEqual(page.records.first?.message, "Remote pull failed")
        XCTAssertEqual(page.records.first?.details, "raw detail")
    }
}
