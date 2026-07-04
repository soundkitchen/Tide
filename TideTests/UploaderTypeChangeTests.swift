import XCTest
import GRDB
import TideCore
@testable import Tide

/// ファイル → 同名ディレクトリ置換（Issue #52）の Uploader 側防衛の配線テスト。
/// `processUpload` は `NoFollowFileReader` の `.isDirectory` を notFound と同様に
/// 「delete への変換」で処理する。旧挙動は read 時の EISDIR が汎用リトライに乗って
/// 5 回 give-up ＝旧ファイルの S3 delete が発行されず、マニフェストに
/// 「ファイルと同名配下」が両立する不整合が残っていた。
/// 変換経路は S3 呼び出し前に return するので、ダミー資格情報の実クライアントで駆動できる。
final class UploaderTypeChangeTests: XCTestCase {
    func testUploadRowForDirectoryConvertsToDelete() async throws {
        let env = try makeTideTestEnv(prefix: "tide-uploader-typechange")
        let path = "was-file.txt"
        try FileManager.default.createDirectory(
            at: env.root.appendingPathComponent(path), withIntermediateDirectories: true
        )

        // ダミー資格情報の実 TideS3Client（構築はオフラインで完結し、ネットワークへは出ない）。
        let (s3, config) = try makeOfflineS3AndConfig()
        let uploader = Uploader(
            s3: s3, db: env.db, syncRoot: env.root, deviceId: "devT",
            config: config, transferStore: env.store
        )

        let item: UploadQueueRecord = try await env.db.pool.write { db in
            var rec = UploadQueueRecord(
                id: nil, path: path, operation: "upload",
                enqueuedAt: 1_000, attempts: 2, nextRetryAt: nil, lastError: nil
            )
            try rec.insert(db)
            return rec
        }

        try await uploader.process(item)

        let rows = try await env.db.pool.read { db in
            try UploadQueueRecord.filter(Column("path") == path).fetchAll(db)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.operation, "delete",
            "ディレクトリ化した path の upload 行は delete へ変換される（EISDIR の give-up にしない）"
        )
        XCTAssertEqual(rows.first?.id, item.id, "既存行の operation を書き換える（新行は作らない）")
    }

    /// dir → file 置換の鏡像（PR #53 レビュー #5）: 祖先がファイル化した stale な子 upload 行は
    /// open が ENOTDIR で失敗する。汎用 5 回リトライ → give-up（delete 未発行）に落とさず、
    /// notFound / isDirectory と同じ delete 変換に含める。
    func testUploadRowUnderFileAncestorConvertsToDelete() async throws {
        let env = try makeTideTestEnv(prefix: "tide-uploader-enotdir")
        try Data("f".utf8).write(to: env.root.appendingPathComponent("was-dir"))

        let (s3, config) = try makeOfflineS3AndConfig()
        let uploader = Uploader(
            s3: s3, db: env.db, syncRoot: env.root, deviceId: "devT",
            config: config, transferStore: env.store
        )

        let item: UploadQueueRecord = try await env.db.pool.write { db in
            var rec = UploadQueueRecord(
                id: nil, path: "was-dir/child.txt", operation: "upload",
                enqueuedAt: 1_000, attempts: 2, nextRetryAt: nil, lastError: nil
            )
            try rec.insert(db)
            return rec
        }

        try await uploader.process(item)

        let rows = try await env.db.pool.read { db in
            try UploadQueueRecord.filter(Column("path") == "was-dir/child.txt").fetchAll(db)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operation, "delete", "ENOTDIR も delete へ変換される")
    }
}
