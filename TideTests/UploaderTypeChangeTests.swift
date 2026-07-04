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
        let s3 = try TideS3Client(
            credentials: AWSCredentials(accessKeyId: "AKIATESTDUMMY", secretAccessKey: "dummy"),
            region: "us-east-1", bucket: "tide-test-bucket", deviceId: "devT"
        )
        let suite = "tide-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let uploader = Uploader(
            s3: s3, db: env.db, syncRoot: env.root, deviceId: "devT",
            config: ConfigStore(defaults: defaults), transferStore: env.store
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
}
