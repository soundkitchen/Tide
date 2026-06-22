import XCTest
import CryptoKit
import GRDB
@testable import Tide

/// アップロード側の並行更新検出（Issue #25 / A）の解決配線を、フェイクの S3 ストリーミングシームと
/// 実 DB（一時ファイル）で結合検証する。`SyncEngine.resolveUploadConflict`（nonisolated static）を
/// 直接駆動し、退避コピー生成・両版保持・正規パス=リモート・キュー行ライフサイクル（id 基準）を固定する。
/// D1（reconcile/削除/scan 配線の結合テスト整備）のシーム利用の先駆けも兼ねる。
final class UploaderConflictTests: XCTestCase {

    /// recordIssue クロージャの呼び出し回数を数えるだけの Sendable スパイ（Error は非 Sendable なので保持しない）。
    private actor IssueSpy {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func makeEnv() throws -> (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL) {
        let e = try makeTideTestEnv(prefix: "tide-upload-conflict")
        return (e.db, e.store, e.root, e.tmp)
    }

    private func sha(_ data: Data) -> String { HashCalculator.hex(SHA256.hash(data: data)) }

    /// リモート版（正規パスへ下ろす版）の権威 entry。`FakeRangedDownloadClient` が返す内容と整合させる。
    private func remoteEntry(for data: Data, versionId: String = "ver-remote", etag: String = "etag-remote") -> ManifestFileEntry {
        ManifestFileEntry(
            size: Int64(data.count),
            mtime: "2026-06-10T00:00:00Z",
            sha256: sha(data),
            s3VersionId: versionId,
            etag: etag,
            deviceId: "devR",
            uploadedAt: "2026-06-10T00:00:00Z"
        )
    }

    private func writeCanonical(_ root: URL, _ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func seedFileRecord(_ db: LocalDatabase, path: String, sha: String, size: Int64) async throws {
        try await db.pool.write { db in
            var rec = FileRecord(
                path: path, size: size, mtime: 1_780_000_000.5, sha256: sha,
                s3VersionId: "ver-base", s3Etag: "etag-base",
                lastSyncedAt: 1_780_000_000, updatedAt: 1_780_000_000
            )
            try rec.save(db)
        }
    }

    @discardableResult
    private func enqueueUpload(_ db: LocalDatabase, path: String, now: Double = 1_780_000_000, replace: Bool = false) async throws -> UploadQueueRecord {
        try await db.pool.write { db in
            var rec = UploadQueueRecord(
                id: nil, path: path, operation: "upload",
                enqueuedAt: now, attempts: 0, nextRetryAt: nil, lastError: nil
            )
            try rec.insert(db, onConflict: replace ? .replace : .abort)
            return rec
        }
    }

    private func makeDownloader(client: any RangedDownloadClient, env: (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL)) -> Downloader {
        Downloader(downloadClient: client, db: env.db, syncRoot: env.root, tmpDir: env.tmp, deviceId: "devL", transferStore: env.store)
    }

    private func fetchQueueRows(_ db: LocalDatabase, path: String) async throws -> [UploadQueueRecord] {
        try await db.pool.read { db in
            try UploadQueueRecord.filter(Column("path") == path).fetchAll(db)
        }
    }

    // MARK: - happy path

    /// 後発端末: ローカル編集を (local copy …) へ退避し、リモート版を versionId 指定で正規パスへ下ろす。
    func testResolveUploadConflictHappyPath() async throws {
        let env = try makeEnv()
        let path = "notes.txt"
        let localBytes = TestData.deterministicBytes(2048, salt: 1)   // 自分の編集
        let remoteBytes = TestData.deterministicBytes(3000, salt: 2)  // 相手の編集（別内容・別サイズ）

        try writeCanonical(env.root, path, localBytes)
        try await seedFileRecord(env.db, path: path, sha: sha(localBytes), size: Int64(localBytes.count))
        let item = try await enqueueUpload(env.db, path: path)

        let entry = remoteEntry(for: remoteBytes)
        let fake = FakeRangedDownloadClient(fullData: remoteBytes, etag: entry.etag)
        let dl = makeDownloader(client: fake, env: env)
        let spy = IssueSpy()

        let result = await SyncEngine.resolveUploadConflict(
            item: item, remoteEntry: entry, db: env.db, downloader: dl,
            recordIssue: { _ in await spy.record() }
        )

        // 行を id 基準で除去し、退避コピーを作った。
        XCTAssertTrue(result.tookOwnership)
        let copyRelative = try XCTUnwrap(result.conflictCopyPath)
        let spyCount = await spy.count
        XCTAssertEqual(spyCount, 0, "happy path では recordIssue を呼ばない")

        // 正規パス = リモート版。
        let canonical = try Data(contentsOf: env.root.appendingPathComponent(path))
        XCTAssertEqual(canonical, remoteBytes, "正規パスにはリモート版が下りる")

        // 退避コピー = 自分の編集。
        let copy = try Data(contentsOf: env.root.appendingPathComponent(copyRelative))
        XCTAssertEqual(copy, localBytes, "退避コピーには自分の編集が残る")

        // FileRecord はリモート版の identity（次回 pull が no-op になる）。
        let rec = try await env.db.pool.read { db in try FileRecord.fetchOne(db, key: path) }
        let unwrapped = try XCTUnwrap(rec)
        XCTAssertEqual(unwrapped.sha256, entry.sha256)
        XCTAssertEqual(unwrapped.s3VersionId, entry.s3VersionId)
        XCTAssertEqual(unwrapped.s3Etag, entry.etag)

        // リモート版は versionId 指定で取得した（本体 PUT が最新を自分の内容に変えているため）。
        XCTAssertEqual(fake.lastVersionId, entry.s3VersionId)

        // 処理した item.id のキュー行は消えている。
        let rows = try await fetchQueueRows(env.db, path: path)
        XCTAssertTrue(rows.isEmpty, "解決後はこの path のキュー行が残らない")
    }

    // MARK: - BUG2 回帰（リネームはキュー行を上回らない → delete-marker を出さない）

    /// リモート版 download が失敗（404）しても、キュー行は item.id 基準で除去済み・ローカル編集は退避済み。
    /// 行が残らないので再処理が convertQueueItemToDelete → リモート delete-marker を打つことはあり得ない
    /// （canonical 欠落は次回 pull の local-absent→download で回復する）。
    func testResolveUploadConflictDownloadFailureLeavesNoQueueRowAndNoDeleteMarker() async throws {
        let env = try makeEnv()
        let path = "docs/report.bin"
        let localBytes = TestData.deterministicBytes(4096, salt: 3)
        let remoteBytes = TestData.deterministicBytes(4096, salt: 4)

        try writeCanonical(env.root, path, localBytes)
        try await seedFileRecord(env.db, path: path, sha: sha(localBytes), size: Int64(localBytes.count))
        let item = try await enqueueUpload(env.db, path: path)

        let entry = remoteEntry(for: remoteBytes)
        let fake = FakeRangedDownloadClient(fullData: remoteBytes, etag: entry.etag, notFound: true) // 404
        let dl = makeDownloader(client: fake, env: env)
        let spy = IssueSpy()

        let result = await SyncEngine.resolveUploadConflict(
            item: item, remoteEntry: entry, db: env.db, downloader: dl,
            recordIssue: { _ in await spy.record() }
        )

        XCTAssertTrue(result.tookOwnership, "行は除去済みなので所有権は取得している")
        let copyRelative = try XCTUnwrap(result.conflictCopyPath, "退避コピーは作られている")
        let spyCount = await spy.count
        XCTAssertEqual(spyCount, 1, "download 失敗を recordIssue で 1 回可視化する")

        // 退避コピーには自分の編集が残る。
        let copy = try Data(contentsOf: env.root.appendingPathComponent(copyRelative))
        XCTAssertEqual(copy, localBytes)

        // 正規パスは download 失敗で欠落（次回 pull で回復）。
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent(path).path))

        // 肝: キュー行は残っていない（残っていれば再処理が delete に変換し得る）。
        let rows = try await fetchQueueRows(env.db, path: path)
        XCTAssertTrue(rows.isEmpty, "download 失敗でもキュー行は残さない（delete-marker を出さない安全性）")

        // rename が FileRecord を削除済み。
        let rec = try await env.db.pool.read { db in try FileRecord.fetchOne(db, key: path) }
        XCTAssertNil(rec)
    }

    // MARK: - BUG1 回帰（処理中に届いた同 path の新 id 行を巻き込まない）

    /// 処理中に新編集が INSERT OR REPLACE で別 id の行に置換された場合、item.id 基準の除去と
    /// clearQueueByPath=false により、その新行は解決後も生存する（不変条件 [キュー行 id 基準]）。
    func testResolveUploadConflictPreservesConcurrentSamePathRow() async throws {
        let env = try makeEnv()
        let path = "data.bin"
        let localBytes = TestData.deterministicBytes(2048, salt: 5)
        let remoteBytes = TestData.deterministicBytes(2048, salt: 6)

        try writeCanonical(env.root, path, localBytes)
        try await seedFileRecord(env.db, path: path, sha: sha(localBytes), size: Int64(localBytes.count))
        let item = try await enqueueUpload(env.db, path: path)          // 処理対象（id = item.id）

        // 処理中に新編集が届いた想定: UNIQUE(path) を INSERT OR REPLACE で置換 → 新 id の行になる。
        let replacement = try await enqueueUpload(env.db, path: path, now: 1_780_000_010, replace: true)
        XCTAssertNotEqual(replacement.id, item.id, "置換で新 id になる")

        let entry = remoteEntry(for: remoteBytes)
        let fake = FakeRangedDownloadClient(fullData: remoteBytes, etag: entry.etag)
        let dl = makeDownloader(client: fake, env: env)
        let spy = IssueSpy()

        let result = await SyncEngine.resolveUploadConflict(
            item: item, remoteEntry: entry, db: env.db, downloader: dl,
            recordIssue: { _ in await spy.record() }
        )
        XCTAssertTrue(result.tookOwnership)

        // 置換された新行（新編集の再アップロード指示）は生存している。
        let rows = try await fetchQueueRows(env.db, path: path)
        XCTAssertEqual(rows.count, 1, "新編集の行を巻き込み削除していない")
        XCTAssertEqual(rows.first?.id, replacement.id, "生存しているのは置換後の新 id 行")
    }

    // MARK: - RISK3（.alreadyUpToDate の DB identity が次回 pull を no-op にする）

    /// processUpload の .alreadyUpToDate 分岐は「リモート版の {sha,size,etag,versionId} + ローカル stat mtime」を
    /// 記録する。これで ChangeDetector.reconcileIsNoop が真を返し、次回 pull が hash も DB write もせず抜ける。
    func testAlreadyUpToDateIdentityMakesNextPullNoop() throws {
        let remoteBytes = TestData.deterministicBytes(1500, salt: 7)
        let entry = remoteEntry(for: remoteBytes)
        let localMtime = 1_780_000_123.456  // ローカル stat 実値（マニフェスト秒精度とは別）

        // .alreadyUpToDate 分岐が書く FileRecord 相当（mtime はローカル stat、identity はリモート）。
        let known = ChangeDetector.Known(
            size: entry.size, mtime: localMtime, sha256: entry.sha256, isSynced: true
        )
        XCTAssertTrue(
            ChangeDetector.reconcileIsNoop(
                known: known,
                localSize: entry.size, localMtime: localMtime,
                knownEtag: entry.etag, knownVersionId: entry.s3VersionId,
                remoteSha: entry.sha256, remoteEtag: entry.etag, remoteVersionId: entry.s3VersionId
            ),
            "リモート identity + ローカル mtime を記録すれば次回 pull は no-op"
        )

        // 取り違えて自分の PUT identity（別 etag/versionId）を記録すると no-op が外れる（churn する）ことの確認。
        XCTAssertFalse(
            ChangeDetector.reconcileIsNoop(
                known: known,
                localSize: entry.size, localMtime: localMtime,
                knownEtag: "etag-mine", knownVersionId: "ver-mine",
                remoteSha: entry.sha256, remoteEtag: entry.etag, remoteVersionId: entry.s3VersionId
            ),
            "etag/versionId が食い違うと reconcile は no-op にならない"
        )
    }
}
