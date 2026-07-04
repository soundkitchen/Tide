import XCTest
import GRDB
import TideCore
@testable import Tide

/// scan / event 共通の「判定 → CAS / enqueue」配線（D1 / #30）。`performFullScan` と
/// `processEventToQueue` が共有する nonisolated static ヘルパ（`classifyLocalChange` /
/// `enqueueUpload` / `enqueueScanDeletions`）を実 temp DB + 実ファイルで直接駆動し、
/// preDecision/postHash → mtime CAS / enqueue のマッピングと、onConflict の scan(.ignore) /
/// event(.replace) 差、削除検出（集合差分）を固定する。
///
/// 注記: ツリー走査・symlink skip・PathValidator・foundPaths 簿記は @MainActor の
/// `performFullScan` クロージャに、`.syncignore` reload / triggerFullScan ディスパッチ・
/// event の `.deleted` / file-gone → enqueueDelete は @MainActor `processEventToQueue` に残り、
/// 直接駆動面がない（このファイルのスコープ外）。
final class ScanEventWiringTests: XCTestCase {

    private func makeEnv() throws -> (db: LocalDatabase, root: URL) {
        let e = try makeTideTestEnv(prefix: "tide-scan-event-wiring")
        return (e.db, e.root)
    }

    /// 永続化せず値として渡す FileRecord（CAS no-op で DB と食い違う `existing` を作るのに使う）。
    private func makeRecord(path: String, sha: String, size: Int64, mtime: Double) -> FileRecord {
        FileRecord(
            path: path, size: size, mtime: mtime, sha256: sha,
            s3VersionId: "v", s3Etag: "e", lastSyncedAt: 1_000, updatedAt: 1_000
        )
    }

    @discardableResult
    private func seedUploadRow(_ db: LocalDatabase, path: String, attempts: Int) async throws -> Int64 {
        try await db.pool.write { db in
            var rec = UploadQueueRecord(
                id: nil, path: path, operation: "upload",
                enqueuedAt: 1_000, attempts: attempts, nextRetryAt: nil, lastError: nil
            )
            try rec.insert(db)
            return rec.id ?? -1
        }
    }

    private func queueRows(_ db: LocalDatabase, path: String) async throws -> [UploadQueueRecord] {
        try await db.pool.read { db in try UploadQueueRecord.filter(Column("path") == path).fetchAll(db) }
    }

    private func allQueueRows(_ db: LocalDatabase) async throws -> [UploadQueueRecord] {
        try await db.pool.read { db in try UploadQueueRecord.fetchAll(db) }
    }

    // MARK: - classifyLocalChange

    func testNewFileEnqueues() async throws {
        let env = try makeEnv()
        let path = "a.txt"
        let url = try writeFile(env.root, path, TestData.deterministicBytes(100, salt: 1))
        let d = try await SyncEngine.classifyLocalChange(
            existing: nil, fileURL: url, size: 100, mtime: 1_000, relativePath: path, db: env.db
        )
        XCTAssertEqual(d, .enqueue, "未知ファイルは要アップロード")
    }

    func testUnchangedSkips() async throws {
        let env = try makeEnv()
        let path = "a.txt"
        let bytes = TestData.deterministicBytes(100, salt: 2)
        let url = try writeFile(env.root, path, bytes)
        let rec = makeRecord(path: path, sha: TestData.shaHex(bytes), size: 100, mtime: 1_000)
        try await saveFileRecord(env.db, rec)
        let d = try await SyncEngine.classifyLocalChange(
            existing: rec, fileURL: url, size: 100, mtime: 1_000, relativePath: path, db: env.db
        )
        XCTAssertEqual(d, .skip, "size/mtime 一致は変更なし（hash も見ない）")
    }

    func testSizeMismatchEnqueuesWithoutHash() async throws {
        let env = try makeEnv()
        let path = "a.txt"
        let rec = makeRecord(path: path, sha: "deadbeef", size: 100, mtime: 1_000)
        // file を作らない: size 不一致は hash に到達せず enqueue するので fileURL は読まれない。
        let d = try await SyncEngine.classifyLocalChange(
            existing: rec, fileURL: env.root.appendingPathComponent(path),
            size: 200, mtime: 1_000, relativePath: path, db: env.db
        )
        XCTAssertEqual(d, .enqueue, "size 不一致は hash なしで enqueue")
    }

    func testMtimeDriftSameShaRepairsViaCAS() async throws {
        let env = try makeEnv()
        let path = "a.txt"
        let bytes = TestData.deterministicBytes(300, salt: 3)
        let shaA = TestData.shaHex(bytes)
        let url = try writeFile(env.root, path, bytes)
        let rec = makeRecord(path: path, sha: shaA, size: 300, mtime: 1_000)
        try await saveFileRecord(env.db, rec)

        let d = try await SyncEngine.classifyLocalChange(
            existing: rec, fileURL: url, size: 300, mtime: 1_000.5, relativePath: path, db: env.db
        )
        XCTAssertEqual(d, .mtimeRepaired, "mtime ドリフト・内容同一は CAS で mtime 修復")
        let updated = try await fetchFileRecord(env.db, path: path)
        XCTAssertEqual(updated?.mtime ?? 0, 1_000.5, accuracy: 0.000_01, "DB mtime が新 stat 値へ修復")
    }

    func testContentChangedEnqueues() async throws {
        let env = try makeEnv()
        let path = "a.txt"
        let onDisk = TestData.deterministicBytes(300, salt: 4)         // 実内容（sha 変化）
        let url = try writeFile(env.root, path, onDisk)
        let rec = makeRecord(path: path, sha: TestData.shaHex(TestData.deterministicBytes(300, salt: 99)), size: 300, mtime: 1_000)
        try await saveFileRecord(env.db, rec)

        let d = try await SyncEngine.classifyLocalChange(
            existing: rec, fileURL: url, size: 300, mtime: 1_000.5, relativePath: path, db: env.db
        )
        XCTAssertEqual(d, .enqueue, "mtime ドリフト + 内容変化は enqueue")
        let after = try await fetchFileRecord(env.db, path: path)
        XCTAssertEqual(after?.mtime ?? 0, 1_000, accuracy: 0.000_01, "enqueue 経路は mtime を修復しない")
    }

    func testCASNoopWhenDbShaChangedConcurrently() async throws {
        let env = try makeEnv()
        let path = "a.txt"
        let bytes = TestData.deterministicBytes(300, salt: 5)
        let shaA = TestData.shaHex(bytes)
        let url = try writeFile(env.root, path, bytes)
        // DB は別 sha（並行 pull が判定〜CAS の間に同 path を更新した状況の模擬）。
        try await saveFileRecord(env.db, makeRecord(path: path, sha: "shaB-deadbeef", size: 300, mtime: 2_000))
        // 渡す existing は stale read（shaA）。
        let stale = makeRecord(path: path, sha: shaA, size: 300, mtime: 1_000)

        let d = try await SyncEngine.classifyLocalChange(
            existing: stale, fileURL: url, size: 300, mtime: 1_000.5, relativePath: path, db: env.db
        )
        XCTAssertEqual(d, .mtimeCASNoop, "CAS は DB の現 sha と食い違うと no-op")
        let after = try await fetchFileRecord(env.db, path: path)
        XCTAssertEqual(after?.mtime ?? 0, 2_000, accuracy: 0.000_01, "CAS no-op は DB mtime を巻き戻さない")
        XCTAssertEqual(after?.sha256, "shaB-deadbeef", "並行更新の sha を保持")
    }

    func testHashUnreadableEnqueues() async throws {
        let env = try makeEnv()
        let path = "a.txt"
        let rec = makeRecord(path: path, sha: "deadbeef", size: 300, mtime: 1_000)
        try await saveFileRecord(env.db, rec)
        // file を作らない: verifyHash に入るが hash 不能（nil）→ enqueue。
        let d = try await SyncEngine.classifyLocalChange(
            existing: rec, fileURL: env.root.appendingPathComponent(path),
            size: 300, mtime: 1_000.5, relativePath: path, db: env.db
        )
        XCTAssertEqual(d, .enqueue, "hash 不能は安全側で enqueue")
    }

    // MARK: - enqueueUpload（onConflict の scan/.ignore vs event/.replace）

    func testEnqueueUploadIgnoreKeepsExistingRow() async throws {
        let env = try makeEnv()
        let path = "q.txt"
        let id = try await seedUploadRow(env.db, path: path, attempts: 3)
        try await SyncEngine.enqueueUpload(db: env.db, path: path, now: 5_000, onConflict: .ignore)
        let rows = try await queueRows(env.db, path: path)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attempts, 3, ".ignore は既存行（attempts）を温存＝リトライ巻き戻し防止")
        XCTAssertEqual(rows.first?.id, id, "id も不変")
    }

    func testEnqueueUploadReplaceResetsRow() async throws {
        let env = try makeEnv()
        let path = "q.txt"
        try await seedUploadRow(env.db, path: path, attempts: 3)
        try await SyncEngine.enqueueUpload(db: env.db, path: path, now: 5_000, onConflict: .replace)
        let rows = try await queueRows(env.db, path: path)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attempts, 0, ".replace は行を置換＝attempts リセット（処理中の同 path を上書き）")
    }

    // MARK: - enqueueDelete（event 経路 / 種別変化 Issue #52）

    /// 追跡中ファイルがディレクトリへ置換されたとき（Issue #52）、event 経路は delete を
    /// `.replace` で enqueue する＝誤分類済みの同 path upload 行（EISDIR でリトライ中）を置換して潰す。
    func testEnqueueDeleteReplacesExistingUploadRow() async throws {
        let env = try makeEnv()
        let path = "x.txt"
        try await seedUploadRow(env.db, path: path, attempts: 3)

        try await SyncEngine.enqueueDelete(db: env.db, path: path, now: 8_000)

        let rows = try await queueRows(env.db, path: path)
        XCTAssertEqual(rows.count, 1, "同 path は 1 行に置換される")
        XCTAssertEqual(rows.first?.operation, "delete", "upload 行は delete 行へ置き換わる")
        XCTAssertEqual(rows.first?.attempts, 0, "置換行は古いリトライ状態を引き継がない")
    }

    func testEnqueueDeleteInsertsWhenAbsent() async throws {
        let env = try makeEnv()
        try await SyncEngine.enqueueDelete(db: env.db, path: "gone.txt", now: 8_000)
        let rows = try await queueRows(env.db, path: "gone.txt")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operation, "delete")
    }

    // MARK: - enqueueDescendantDeletes（dir → file 置換の鏡像 / PR #53 レビュー #3）

    /// `parentPath/` 配下の追跡行だけが delete に乗る。PK 範囲比較（`>= "p/" AND < "p0"`）が
    /// 接頭辞の紛らわしい隣接パス（`x.dirty` / `x.dir2/…`）を巻き込まないことも固定する。
    func testEnqueueDescendantDeletesMatchesOnlyChildren() async throws {
        let env = try makeEnv()
        for p in ["x.dir/a.txt", "x.dir/sub/b.txt", "x.dirty", "x.dir2/c.txt", "y.txt"] {
            try await saveFileRecord(env.db, makeRecord(path: p, sha: "s", size: 1, mtime: 1))
        }
        let n = try await SyncEngine.enqueueDescendantDeletes(db: env.db, parentPath: "x.dir", now: 9_000)
        XCTAssertEqual(n, 2, "x.dir/ 配下の 2 行のみ")
        for p in ["x.dir/a.txt", "x.dir/sub/b.txt"] {
            let rows = try await queueRows(env.db, path: p)
            XCTAssertEqual(rows.first?.operation, "delete", "\(p) は delete に乗る")
        }
        for p in ["x.dirty", "x.dir2/c.txt", "y.txt"] {
            let rows = try await queueRows(env.db, path: p)
            XCTAssertTrue(rows.isEmpty, "\(p) は巻き込まれない")
        }
    }

    func testEnqueueDescendantDeletesNoopWithoutChildren() async throws {
        let env = try makeEnv()
        try await saveFileRecord(env.db, makeRecord(path: "plain.txt", sha: "s", size: 1, mtime: 1))
        let n = try await SyncEngine.enqueueDescendantDeletes(db: env.db, parentPath: "plain.txt", now: 9_000)
        XCTAssertEqual(n, 0, "配下の追跡行が無ければ何も積まない（通常のファイルイベント）")
        let rows = try await allQueueRows(env.db)
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - enqueueScanDeletions（削除検出）

    func testDeletionEnqueuesMissingPaths() async throws {
        let env = try makeEnv()
        for p in ["a", "b", "c"] {
            try await saveFileRecord(env.db, makeRecord(path: p, sha: "s", size: 1, mtime: 1))
        }
        let n = try await SyncEngine.enqueueScanDeletions(db: env.db, foundPaths: ["a", "b"], now: 7_000)
        XCTAssertEqual(n, 1, "実体が見つからない c のみ削除キューへ")
        let cRows = try await queueRows(env.db, path: "c")
        XCTAssertEqual(cRows.first?.operation, "delete")
        let aRows = try await queueRows(env.db, path: "a")
        XCTAssertTrue(aRows.isEmpty, "見つかった path は削除キューに乗らない")
    }

    func testDeletionNoneWhenAllFound() async throws {
        let env = try makeEnv()
        for p in ["a", "b"] {
            try await saveFileRecord(env.db, makeRecord(path: p, sha: "s", size: 1, mtime: 1))
        }
        let n = try await SyncEngine.enqueueScanDeletions(db: env.db, foundPaths: ["a", "b"], now: 7_000)
        XCTAssertEqual(n, 0)
        let rows = try await allQueueRows(env.db)
        XCTAssertTrue(rows.isEmpty, "削除行は積まれない")
    }
}
