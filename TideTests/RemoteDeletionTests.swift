import XCTest
import GRDB
@testable import Tide

/// リモート削除の適用配線（D1 / #30）。`Downloader.applyRemoteDeletion` は `ThreeWayMerge.decide(remote:nil)`
/// の判定を「実 FS 削除 + DB 削除 + ログ」へ振り分ける。この switch マッピングの取り違えは
/// **リモート削除でローカル編集を消す（他端末由来のデータ損失）** に直結するが回帰検出できなかった。
/// `applyRemoteDeletion` は struct メソッドで db / syncRoot を注入保持し S3 アクセスを持たないため、
/// 実 temp DB + temp syncRoot で（プロダクトコード無変更のまま）結合検証する。
/// 駆動型は `UploaderConflictTests`（Issue #25 / A）の踏襲。
final class RemoteDeletionTests: XCTestCase {

    private func makeEnv() throws -> (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL) {
        let e = try makeTideTestEnv(prefix: "tide-remote-deletion")
        return (e.db, e.store, e.root, e.tmp)
    }

    /// 削除は S3 を触らないので共通ヘルパのダミークライアントでよい（streamObject は呼ばれない）。
    private func makeDownloader(env: (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL)) -> Downloader {
        makeTestDownloader(db: env.db, syncRoot: env.root, tmpDir: env.tmp, store: env.store)
    }

    private func countLogs(_ db: LocalDatabase, type: SyncLogEventType, path: String) async throws -> Int {
        try await db.pool.read { db in
            try SyncLogRecord
                .filter(Column("event_type") == type.rawValue && Column("path") == path)
                .fetchCount(db)
        }
    }

    // MARK: - .deleteLocal（base == local＝未編集 → 削除）

    func testDeleteLocalRemovesFileAndRecordWhenUnmodified() async throws {
        let env = try makeEnv()
        let path = "docs/note.txt"
        let bytes = TestData.deterministicBytes(512, salt: 3)
        let url = try writeFile(env.root, path, bytes)
        try await seedFileRecord(env.db, path: path, sha: TestData.shaHex(bytes), size: Int64(bytes.count))

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: path)

        XCTAssertTrue(removed, "未編集ならリモート削除を反映して削除する")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "ローカルファイルが削除される")
        let rec = try await fetchFileRecord(env.db, path: path)
        XCTAssertNil(rec, "FileRecord も削除される")
        let deleteLogs = try await countLogs(env.db, type: .delete, path: path)
        XCTAssertEqual(deleteLogs, 1, "sync_log に delete が 1 件積まれる")
    }

    // MARK: - .keepLocalRemoteDeleted（編集済み / 未追跡 / unreadable → 温存）

    func testKeepLocalWhenModified() async throws {
        let env = try makeEnv()
        let path = "docs/edited.txt"
        let onDisk = TestData.deterministicBytes(800, salt: 7)            // 現在のローカル内容
        let baseBytes = TestData.deterministicBytes(800, salt: 9)         // 別内容（= base）
        let url = try writeFile(env.root, path, onDisk)
        try await seedFileRecord(env.db, path: path, sha: TestData.shaHex(baseBytes), size: Int64(baseBytes.count))

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: path)

        XCTAssertFalse(removed, "ローカル編集済みなら温存する（データ損失を防ぐ）")
        XCTAssertEqual(try Data(contentsOf: url), onDisk, "ローカルファイルは無変更で残る")
        let rec = try await fetchFileRecord(env.db, path: path)
        XCTAssertNotNil(rec, "FileRecord も残る")
        let conflictLogs = try await countLogs(env.db, type: .conflict, path: path)
        XCTAssertEqual(conflictLogs, 1, "sync_log に conflict（温存）が 1 件積まれる")
    }

    func testKeepLocalWhenUntracked() async throws {
        let env = try makeEnv()
        let path = "docs/untracked.txt"
        let bytes = TestData.deterministicBytes(640, salt: 11)
        let url = try writeFile(env.root, path, bytes)
        // FileRecord を seed しない（base == nil＝未追跡）。

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: path)

        XCTAssertFalse(removed, "未追跡ローカルをリモート削除で消さない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "ファイルは温存")
    }

    func testKeepLocalWhenUnreadable() async throws {
        let env = try makeEnv()
        let path = "docs/blob"
        // パス位置にディレクトリを置く: fileExists==true・symlink でない・sha256(of:) は throw → .unreadable。
        let dir = env.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await seedFileRecord(env.db, path: path, sha: "deadbeef", size: 1)

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: path)

        XCTAssertFalse(removed, "unreadable は保守的に温存（.keepLocalRemoteDeleted）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "実体は温存")
        let rec = try await fetchFileRecord(env.db, path: path)
        XCTAssertNotNil(rec, "温存分岐は FileRecord を削除しない")
    }

    // MARK: - symlink 削除拒否（DB に触れる前に早期 return）

    func testRefusesSymbolicLink() async throws {
        let env = try makeEnv()
        let targetRel = "docs/target.txt"
        let linkRel = "docs/link.txt"
        let targetBytes = TestData.deterministicBytes(256, salt: 13)
        let target = try writeFile(env.root, targetRel, targetBytes)
        let link = env.root.appendingPathComponent(linkRel)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await seedFileRecord(env.db, path: linkRel, sha: "deadbeef", size: 1)

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: linkRel)

        XCTAssertFalse(removed, "symlink はリンク先実体を消さないため削除しない")
        XCTAssertEqual(try Data(contentsOf: target), targetBytes, "リンク先実体は無変更")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path), "symlink 自体も残る")
        let rec = try await fetchFileRecord(env.db, path: linkRel)
        XCTAssertNotNil(rec, "symlink は DB に触れる前に早期 return＝FileRecord 未削除")
    }

    // MARK: - ローカル不在（孤児 FileRecord 掃除）

    func testAbsentLocalDeletesRecordOnly() async throws {
        let env = try makeEnv()
        let path = "docs/ghost.txt"
        // ファイルは作らず FileRecord だけ seed（孤児）。
        try await seedFileRecord(env.db, path: path, sha: "deadbeef", size: 1)

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: path)

        XCTAssertFalse(removed, "削除は実行しない（ファイルが無い）")
        let rec = try await fetchFileRecord(env.db, path: path)
        XCTAssertNil(rec, "孤児 FileRecord は掃除される")
        let deleteLogs = try await countLogs(env.db, type: .delete, path: path)
        XCTAssertEqual(deleteLogs, 0, "不在掃除はログを積まない")
    }
}
