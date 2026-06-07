import XCTest
@testable import Tide

/// `SyncEngine.pruneOrphanTransfers`（static 本体）の分岐 → 実 I/O の配線を、実 DB（一時ファイル）で
/// 回帰固定する。特に download の clear 分岐（tmp 消失 / stale）が行を落とす前に
/// `invalidateShardCache` する修正（受け入れテスト §6-2 の取り残しバグ）を直接検証する。
final class TransferPruneTests: XCTestCase {
    // MARK: - ヘルパ

    /// abort 呼び出しの記録用（@Sendable クロージャから安全に追記するため actor）。
    private actor AbortRecorder {
        private(set) var calls: [(key: String, uploadId: String)] = []
        func record(key: String, uploadId: String) { calls.append((key, uploadId)) }
    }

    private func makeEnv() throws -> (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-prune-tests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let db = try LocalDatabase(at: base.appendingPathComponent("db.sqlite"))
        return (db, TransferStateStore(db: db), root, tmp)
    }

    /// path が属するシャードの shard_state 行を seed する（ManifestReader が fetch 時点で記録する状況の模擬）。
    private func seedShardState(db: LocalDatabase, path: String, etag: String) async throws {
        try await db.pool.write { dbq in
            var rec = ShardStateRecord(
                shardId: ManifestSharding.shardId(for: path),
                etag: etag,
                fetchedAt: Date().timeIntervalSince1970
            )
            try rec.save(dbq)
        }
    }

    private func shardEtag(db: LocalDatabase, path: String) async throws -> String? {
        try await db.pool.read { dbq in
            try ShardStateRecord.fetchOne(dbq, key: ManifestSharding.shardId(for: path))?.etag
        }
    }

    /// abort 記録つきで prune 本体を実行する。
    private func runPrune(
        env: (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL),
        now: Date = Date(),
        recorder: AbortRecorder? = nil
    ) async {
        await SyncEngine.pruneOrphanTransfers(
            db: env.db, store: env.store, syncRoot: env.root, now: now,
            abortUpload: { key, uploadId in await recorder?.record(key: key, uploadId: uploadId) }
        )
    }

    // MARK: - download: clear 分岐（本命回帰）

    /// tmp が消えた download 行は、行削除と同時にシャードキャッシュを invalidate する
    /// （これを欠くと FileRecord 無し + shard_state は実 etag のままで、当該ファイルが
    /// シャードのリモート変化まで永久に再 DL されない）。
    func testClearBranchTmpMissingInvalidatesShardCacheAndClearsRow() async throws {
        let env = try makeEnv()
        let rp = "docs/lost.bin"
        let missingTmp = env.tmp.appendingPathComponent("dl-missing.part").path
        try await env.store.beginDownload(path: rp, tmpPath: missingTmp, expectedEtag: "etag-r")
        try await seedShardState(db: env.db, path: rp, etag: "real-etag")

        await runPrune(env: env)

        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNil(row, "tmp 消失行は削除される")
        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertEqual(etag, "", "行を落とす前にシャードキャッシュが sentinel 化される（取り残し防止）")
    }

    /// stale（7 日超）な download 行は tmp ごと破棄されるが、同様に invalidate される。
    func testClearBranchStaleRemovesTmpInvalidatesAndClearsRow() async throws {
        let env = try makeEnv()
        let rp = "docs/stale.bin"
        let tmpFile = env.tmp.appendingPathComponent("dl-stale.part")
        try Data([1, 2, 3]).write(to: tmpFile)
        try await env.store.beginDownload(path: rp, tmpPath: tmpFile.path, expectedEtag: "etag-r")
        try await seedShardState(db: env.db, path: rp, etag: "real-etag")

        // now を 8 日進めて「7 日より古い行」にする（updatedAt は seed 時の実時刻）。
        await runPrune(env: env, now: Date().addingTimeInterval(8 * 86_400))

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpFile.path), "stale tmp は削除される")
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNil(row, "stale 行は削除される")
        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertEqual(etag, "", "clear（stale）でもシャードキャッシュが sentinel 化される")
    }

    // MARK: - download: resumable 分岐（既存挙動の回帰固定）

    /// tmp あり・新しい行は再開可能として温存され、シャードキャッシュの invalidate（再 arm）のみ行う。
    func testResumableBranchKeepsRowAndTmpAndRearms() async throws {
        let env = try makeEnv()
        let rp = "docs/resumable.bin"
        let tmpFile = env.tmp.appendingPathComponent("dl-resumable.part")
        try Data([1, 2, 3, 4]).write(to: tmpFile)
        try await env.store.beginDownload(path: rp, tmpPath: tmpFile.path, expectedEtag: "etag-r")
        try await seedShardState(db: env.db, path: rp, etag: "real-etag")

        await runPrune(env: env)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpFile.path), "再開用 tmp は温存される")
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNotNil(row, "再開可能行は温存される")
        XCTAssertEqual(row?.tmpPath, tmpFile.path)
        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertEqual(etag, "", "再 arm: シャードキャッシュが sentinel 化される")
    }

    // MARK: - upload 分岐

    /// ローカルファイルが消えた upload 行は MPU を abort して行を削除する。
    func testUploadOrphanAbortsMultipartAndClearsRow() async throws {
        let env = try makeEnv()
        let rp = "docs/gone.bin"  // ローカルに作らない
        try await env.store.beginUpload(path: rp, uploadId: "u-123", partSize: 5 << 20, fileMtime: 1, fileSize: 10)
        let recorder = AbortRecorder()

        await runPrune(env: env, recorder: recorder)

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.key, "files/\(rp)")
        XCTAssertEqual(calls.first?.uploadId, "u-123")
        let row = try await env.store.loadUpload(path: rp)
        XCTAssertNil(row, "オーファン upload 行は削除される")
    }

    /// ローカルファイルが実在し新しい upload 行は温存される（abort も呼ばれない）。
    func testUploadWithLocalFileIsKept() async throws {
        let env = try makeEnv()
        let rp = "docs/alive.bin"
        let local = env.root.appendingPathComponent(rp)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9, 9, 9]).write(to: local)
        try await env.store.beginUpload(path: rp, uploadId: "u-456", partSize: 5 << 20, fileMtime: 1, fileSize: 3)
        let recorder = AbortRecorder()

        await runPrune(env: env, recorder: recorder)

        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "存命ファイルの MPU は abort されない")
        let row = try await env.store.loadUpload(path: rp)
        XCTAssertNotNil(row, "再開可能な upload 行は温存される")
    }
}
