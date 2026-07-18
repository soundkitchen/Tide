import XCTest
import GRDB
import TideCore
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

    // MARK: - 空 dir 殻の掃除（Issue #67: `.deleteLocal` 後の removeEmptyAncestors）

    /// `.deleteLocal` を成立させるフィクスチャ（実ファイル + 同 sha の FileRecord）を作る。
    private func seedDeletable(_ env: (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL), path: String, salt: UInt8) async throws {
        let bytes = TestData.deterministicBytes(256, salt: salt)
        _ = try writeFile(env.root, path, bytes)
        try await seedFileRecord(env.db, path: path, sha: TestData.shaHex(bytes), size: Int64(bytes.count))
    }

    private func exists(_ env: (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL), _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: env.root.appendingPathComponent(relative).path)
    }

    func testEmptyAncestorsRemovedRecursively() async throws {
        let env = try makeEnv()
        let path = "a/b/c.txt"
        try await seedDeletable(env, path: path, salt: 30)

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: path)

        XCTAssertTrue(removed)
        XCTAssertFalse(exists(env, "a/b"), "空になった直近の親を掃除")
        XCTAssertFalse(exists(env, "a"), "祖先方向へ再帰して掃除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.root.path), "syncRoot 自体は消さない")
    }

    func testSiblingFilePreservesDirectory() async throws {
        let env = try makeEnv()
        try await seedDeletable(env, path: "a/b/target.txt", salt: 31)
        _ = try writeFile(env.root, "a/b/keep.txt", TestData.deterministicBytes(64, salt: 32))

        _ = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: "a/b/target.txt")

        XCTAssertTrue(exists(env, "a/b/keep.txt"), "兄弟ファイルは無傷")
        XCTAssertTrue(exists(env, "a/b"), "空でない dir は温存（rmdir が ENOTEMPTY で打ち切り）")
    }

    func testSiblingEmptyDirStopsAtParent() async throws {
        let env = try makeEnv()
        try await seedDeletable(env, path: "a/b/target.txt", salt: 33)
        // ユーザが意図して作った空 dir（同期対象外）を兄弟に置く。
        try FileManager.default.createDirectory(
            at: env.root.appendingPathComponent("a/empty"), withIntermediateDirectories: true)

        _ = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: "a/b/target.txt")

        XCTAssertFalse(exists(env, "a/b"), "削除ファイルの直近親（空）は掃除")
        XCTAssertTrue(exists(env, "a/empty"), "ユーザの空 dir は巻き込まない")
        XCTAssertTrue(exists(env, "a"), "空 dir が残る親は温存（掃除は削除 path の祖先のみ + rmdir 打ち切り）")
    }

    func testKeepLocalDoesNotSweep() async throws {
        let env = try makeEnv()
        let path = "k/edited.txt"
        let onDisk = TestData.deterministicBytes(300, salt: 34)
        let baseBytes = TestData.deterministicBytes(300, salt: 35)   // base != local（編集済み）
        _ = try writeFile(env.root, path, onDisk)
        try await seedFileRecord(env.db, path: path, sha: TestData.shaHex(baseBytes), size: Int64(baseBytes.count))

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: path)

        XCTAssertFalse(removed)
        XCTAssertTrue(exists(env, path), "温存経路（.keepLocalRemoteDeleted）は掃除に入らない")
        XCTAssertTrue(exists(env, "k"))
    }

    func testAbsentLocalDoesNotSweep() async throws {
        let env = try makeEnv()
        // 空 dir + 孤児 record（実ファイル無し）: 孤児掃除経路では dir を触らない。
        try FileManager.default.createDirectory(
            at: env.root.appendingPathComponent("g"), withIntermediateDirectories: true)
        try await seedFileRecord(env.db, path: "g/ghost.txt", sha: "deadbeef", size: 1)

        let removed = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: "g/ghost.txt")

        XCTAssertFalse(removed)
        XCTAssertTrue(exists(env, "g"), "ローカル不在（孤児 record 掃除）経路では dir 殻を掃除しない")
    }

    func testSymlinkEntryPreservesDirectoryAndTarget() async throws {
        let env = try makeEnv()
        // dir に symlink が残っている場合: rmdir は ENOTEMPTY で打ち切り（非再帰＝リンク先へ絶対に踏み込まない）。
        let outside = env.tmp.appendingPathComponent("outside-dir")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let keep = outside.appendingPathComponent("keep.txt")
        try TestData.deterministicBytes(32, salt: 36).write(to: keep)
        try await seedDeletable(env, path: "s/target.txt", salt: 37)
        try FileManager.default.createSymbolicLink(
            at: env.root.appendingPathComponent("s/link"), withDestinationURL: outside)

        _ = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: "s/target.txt")

        XCTAssertTrue(exists(env, "s"), "symlink が残る dir は空でないため温存")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "リンク先実体は無傷（掃除は非再帰）")
    }

    func testDSStoreSymlinkStopsSweep() async throws {
        let env = try makeEnv()
        // `.DS_Store` の名で symlink が置かれている場合は unlink せず打ち切り（regular file 限定ガード）。
        let outside = env.tmp.appendingPathComponent("outside-file.txt")
        try TestData.deterministicBytes(24, salt: 42).write(to: outside)
        try await seedDeletable(env, path: "d3/target.txt", salt: 43)
        try FileManager.default.createSymbolicLink(
            at: env.root.appendingPathComponent("d3/.DS_Store"), withDestinationURL: outside)

        _ = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: "d3/target.txt")

        XCTAssertTrue(exists(env, "d3"), "`.DS_Store` が symlink の dir は掃除しない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "リンク先実体は無傷")
    }

    func testDSStoreOnlyDirectoryIsSwept() async throws {
        let env = try makeEnv()
        try await seedDeletable(env, path: "d/target.txt", salt: 38)
        _ = try writeFile(env.root, "d/.DS_Store", TestData.deterministicBytes(16, salt: 39))

        _ = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: "d/target.txt")

        XCTAssertFalse(exists(env, "d"), ".DS_Store 単独残置は一緒に掃除（Finder 閲覧だけで殻が再残置され続けるのを防ぐ）")
    }

    func testOtherDotfilePreservesDirectory() async throws {
        let env = try makeEnv()
        try await seedDeletable(env, path: "d2/target.txt", salt: 40)
        _ = try writeFile(env.root, "d2/.gitignore", TestData.deterministicBytes(16, salt: 41))

        _ = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: "d2/target.txt")

        XCTAssertTrue(exists(env, "d2/.gitignore"), ".DS_Store 以外の dotfile は消さない")
        XCTAssertTrue(exists(env, "d2"), "dir も温存")
    }

    func testTideDirectoryIsNeverSwept() async throws {
        let env = try makeEnv()
        // 防御的ガード: `.tide` 配下（マニフェスト上は現れないはずのパス）でも殻掃除は踏み込まない。
        try await seedDeletable(env, path: ".tide/sub/x.txt", salt: 44)

        _ = try await makeDownloader(env: env).applyRemoteDeletion(relativePath: ".tide/sub/x.txt")

        XCTAssertTrue(exists(env, ".tide/sub"), "`.tide` 配下は空でも掃除対象外")
        XCTAssertTrue(exists(env, ".tide"))
    }
}
