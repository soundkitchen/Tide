import XCTest
import TideCore
@testable import Tide

/// File Provider 増分列挙の世代ログ（M5 Phase 4）。anchor の安定性・リング上限・
/// 永続化の検証（bucket / スキーマ不一致は cold 扱い）を固定する。
final class ManifestGenerationLogTests: XCTestCase {
    private func entry(sha: String) -> ManifestFileEntry {
        ManifestFileEntry(
            size: 1, mtime: "2026-07-04T00:00:00Z", sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: "2026-07-04T00:00:00Z"
        )
    }

    private func snapshot(files: [String: ManifestFileEntry], etags: [String: String] = ["ab": "e1"]) -> ManifestSnapshotLoader.SnapshotResult {
        ManifestSnapshotLoader.SnapshotResult(files: files, shardEtags: etags)
    }

    func testColdAppendCreatesFirstGeneration() {
        let (payload, appended) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")]),
            anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
            to: nil, bucket: "b1"
        )
        XCTAssertTrue(appended)
        XCTAssertEqual(payload.generations.map(\.anchor), ["g1"])
        XCTAssertEqual(payload.bucket, "b1")
    }

    func testUnchangedFilesKeepAnchorButRefreshEtags() {
        let (first, _) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")], etags: ["ab": "e1"]),
            anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
            to: nil, bucket: "b1"
        )
        // 同一内容・etag だけ変化（シャード書き直し）: 世代は増えず anchor 安定、etag は更新
        let (second, appended) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")], etags: ["ab": "e2"]),
            anchor: "g2-unused", fetchedAt: Date(timeIntervalSince1970: 200),
            to: first, bucket: "b1"
        )
        XCTAssertFalse(appended)
        XCTAssertEqual(second.generations.map(\.anchor), ["g1"])
        XCTAssertEqual(second.generations.last?.shardEtags, ["ab": "e2"])
        XCTAssertEqual(second.generations.last?.fetchedAt, Date(timeIntervalSince1970: 200))
    }

    func testChangedFilesAppendNewGeneration() {
        let (first, _) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")]),
            anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
            to: nil, bucket: "b1"
        )
        let (second, appended) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "2")]),
            anchor: "g2", fetchedAt: Date(timeIntervalSince1970: 200),
            to: first, bucket: "b1"
        )
        XCTAssertTrue(appended)
        XCTAssertEqual(second.generations.map(\.anchor), ["g1", "g2"])
        // 旧世代は anchor で引ける（enumerateChanges の diff 起点）
        XCTAssertEqual(
            ManifestGenerationLog.generation(anchor: "g1", in: second)?.files["a.txt"]?.sha256, "1"
        )
        XCTAssertEqual(ManifestGenerationLog.latest(of: second)?.anchor, "g2")
    }

    func testRingPrunesOldestBeyondMax() {
        var payload: ManifestGenerationLog.Payload?
        for i in 0..<12 {
            (payload, _) = ManifestGenerationLog.appending(
                snapshot: snapshot(files: ["a.txt": entry(sha: "\(i)")]),
                anchor: "g\(i)", fetchedAt: Date(timeIntervalSince1970: Double(i)),
                to: payload, bucket: "b1", maxGenerations: 3
            )
        }
        XCTAssertEqual(payload?.generations.map(\.anchor), ["g9", "g10", "g11"])
        XCTAssertNil(ManifestGenerationLog.generation(anchor: "g0", in: payload), "落ちた世代は引けない = syncAnchorExpired 行き")
    }

    func testBucketMismatchStartsFresh() {
        let (first, _) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")]),
            anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
            to: nil, bucket: "b1"
        )
        // 別バケットの payload は無効（前世代と diff しない）
        let (second, appended) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")]),
            anchor: "g-new", fetchedAt: Date(timeIntervalSince1970: 200),
            to: first, bucket: "b2"
        )
        XCTAssertTrue(appended)
        XCTAssertEqual(second.bucket, "b2")
        XCTAssertEqual(second.generations.map(\.anchor), ["g-new"])
    }

    func testEncodeDecodeRoundTrip() throws {
        let (payload, _) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["docs/a.txt": entry(sha: "1")]),
            anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
            to: nil, bucket: "b1"
        )
        let decoded = try ManifestGenerationLog.decode(ManifestGenerationLog.encode(payload))
        XCTAssertEqual(decoded, payload)
    }

    func testDecodeRejectsUnsupportedSchemaVersion() throws {
        var payload = ManifestGenerationLog.Payload(schemaVersion: 999, bucket: "b1", generations: [])
        payload.schemaVersion = 999
        let data = try JSONEncoder().encode(payload)
        XCTAssertThrowsError(try ManifestGenerationLog.decode(data))
    }

    func testLoadValidatesBucketAndCorruption() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")

        let (payload, _) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")]),
            anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
            to: nil, bucket: "b1"
        )
        try ManifestGenerationLog.save(payload, url: url)

        XCTAssertEqual(ManifestGenerationLog.load(bucket: "b1", url: url), payload)
        XCTAssertNil(ManifestGenerationLog.load(bucket: "other", url: url), "bucket 不一致は無効")
        XCTAssertNil(ManifestGenerationLog.load(bucket: "b1", url: dir.appendingPathComponent("missing.json")), "欠落は nil")

        try Data("not json".utf8).write(to: url)
        XCTAssertNil(ManifestGenerationLog.load(bucket: "b1", url: url), "壊れたファイルは nil")
    }
}
