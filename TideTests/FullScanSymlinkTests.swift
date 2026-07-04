import XCTest
import GRDB
import TideCore
@testable import Tide

/// Issue #54: フルスキャン / `.syncignore` 走査の symlink `skipDescendants()` 誤用の回帰テスト。
///
/// deep enumeration は symlink（ディレクトリリンク含む）へそもそも再帰しないが、旧実装は
/// symlink item（＝ファイル）で `skipDescendants()` を呼んでおり、**無関係な隣接ディレクトリ**への
/// 再帰がスキップされていた。フルスキャンでは実在する追跡ファイルが foundPaths から欠落 →
/// 削除検出に乗って S3 へ誤 delete（実機発現・M1 からの潜在バグ）、`.syncignore` 走査では
/// 配下の `.syncignore` が層状マッチャから欠落する。
///
/// 発現は列挙順（APFS のハッシュ順）依存のため、多数の symlink とディレクトリを並べ、
/// 「どの順で列挙されても全ファイル / 全 `.syncignore` が走査に載る」不変条件で固定する
/// （symlink の直後にディレクトリが並ぶ確率を実用上 1 に近づける）。
/// SyncEngine は実物を構築する（init は S3 へ出ない。スキャンも S3 非接触＝ダミー資格情報で安全）。
@MainActor
final class FullScanSymlinkTests: XCTestCase {

    private func makeEngine(root: URL, db: LocalDatabase) throws -> SyncEngine {
        let s3 = try TideS3Client(
            credentials: AWSCredentials(accessKeyId: "AKIATESTDUMMY", secretAccessKey: "dummy"),
            region: "us-east-1", bucket: "tide-test-bucket", deviceId: "devT"
        )
        let suite = "tide-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return SyncEngine(
            db: db, s3: s3, syncRoot: root, deviceId: "devT",
            config: ConfigStore(defaults: defaults)
        )
    }

    /// ルート直下の実ファイルを指す file-symlink を 1 本ずつ、子ファイル入りディレクトリと
    /// 同数（12 組）並べたツリーを作る。返値は子ファイルの相対パス一覧。
    private func makeInterleavedTree(root: URL, withSyncignore: Bool = false) throws -> [String] {
        let fm = FileManager.default
        let target = root.appendingPathComponent("target.txt")
        try Data("t".utf8).write(to: target)

        var childPaths: [String] = []
        for i in 0..<12 {
            let dirName = String(format: "d%02d", i)
            let dir = root.appendingPathComponent(dirName, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let child = "\(dirName)/child.txt"
            try TestData.deterministicBytes(64, salt: UInt8(i))
                .write(to: root.appendingPathComponent(child))
            childPaths.append(child)
            if withSyncignore {
                try Data("pat-\(i)\n".utf8).write(to: dir.appendingPathComponent(".syncignore"))
            }
            try fm.createSymbolicLink(
                at: root.appendingPathComponent(String(format: "s%02d.txt", i)),
                withDestinationURL: target
            )
        }
        return childPaths
    }

    /// フルスキャン: symlink が何本あっても全子ファイルが走査に載る＝追跡ファイルが
    /// 削除検出に乗らない（旧実装は隣接ディレクトリの skip で delete 行が積まれた）。
    func testFullScanFindsAllFilesDespiteFileSymlinks() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-symlink")
        let childPaths = try makeInterleavedTree(root: env.root)

        // 全子ファイルを追跡中（stale な値）として seed: 走査で見つかれば upload、
        // 走査から欠落すれば削除検出に落ちて delete 行として観測できる。
        try await env.db.pool.write { db in
            for p in childPaths {
                var rec = FileRecord(
                    path: p, size: 1, mtime: 1, sha256: "stale",
                    s3VersionId: "v", s3Etag: "e", lastSyncedAt: 1_000, updatedAt: 1_000
                )
                try rec.save(db)
            }
        }

        let engine = try makeEngine(root: env.root, db: env.db)
        await engine.triggerFullScan()

        let rows = try await env.db.pool.read { db in try UploadQueueRecord.fetchAll(db) }
        let deletes = rows.filter { $0.operation == "delete" }.map(\.path)
        XCTAssertTrue(deletes.isEmpty, "実在する追跡ファイルが削除検出に乗った（隣接 symlink による skip）: \(deletes)")
        let uploads = Set(rows.filter { $0.operation == "upload" }.map(\.path))
        for p in childPaths {
            XCTAssertTrue(uploads.contains(p), "\(p) が走査から欠落している")
        }
        // symlink 自身は同期対象に乗らない（C2 ゲート維持）。
        XCTAssertTrue(uploads.allSatisfy { !$0.hasPrefix("s") || $0.hasSuffix("child.txt") },
                      "symlink がキューに乗っている: \(uploads)")
    }

    /// `.syncignore` 走査（loadLayeredIgnore）: symlink が何本あっても全ディレクトリの
    /// `.syncignore` が層状マッチャに載る（旧実装は隣接ディレクトリ配下が欠落し得た）。
    func testReloadIgnoreMatcherFindsAllSyncignoresDespiteFileSymlinks() async throws {
        let env = try makeTideTestEnv(prefix: "tide-ignore-symlink")
        _ = try makeInterleavedTree(root: env.root, withSyncignore: true)

        let engine = try makeEngine(root: env.root, db: env.db)
        await engine.reloadIgnoreMatcher()

        let dirs = Set(engine.activeIgnorePatterns.map(\.directory))
        for i in 0..<12 {
            let d = String(format: "d%02d", i)
            XCTAssertTrue(dirs.contains(d), ".syncignore(\(d)) が層状マッチャから欠落している")
        }
    }
}
