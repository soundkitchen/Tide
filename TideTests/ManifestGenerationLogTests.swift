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
        XCTAssertEqual(payload.anchors, ["g1"])
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
        XCTAssertEqual(second.anchors, ["g1"])
        XCTAssertEqual(second.latest.shardEtags, ["ab": "e2"])
        XCTAssertEqual(second.latest.fetchedAt, Date(timeIntervalSince1970: 200))
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
        XCTAssertEqual(second.anchors, ["g1", "g2"])
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
        XCTAssertEqual(payload?.anchors, ["g9", "g10", "g11"])
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
        XCTAssertEqual(second.anchors, ["g-new"])
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
        let payload = ManifestGenerationLog.Payload(
            schemaVersion: 999, bucket: "b1",
            latest: ManifestGenerationLog.Generation(
                anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100), shardEtags: [:], files: [:]),
            history: [])
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

    func testLoadRejectsUnsafePathsInPersistedSnapshot() throws {
        // PR #51 レビュー #3: ディスク由来のログは改ざん/破損しうるので、読込時にも
        // validateRelativePath を再適用し、1 件でも不正なら全体を破棄（cold 扱い）する。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-log-unsafe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")

        let tampered = ManifestGenerationLog.Payload(
            schemaVersion: ManifestGenerationLog.currentSchemaVersion,
            bucket: "b1",
            latest: ManifestGenerationLog.Generation(
                anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
                shardEtags: ["ab": "e1"],
                files: [
                    "ok.txt": entry(sha: "1"),
                    "../escape.txt": entry(sha: "2"),
                ]
            ),
            history: []
        )
        try ManifestGenerationLog.save(tampered, url: url)
        XCTAssertNil(ManifestGenerationLog.load(bucket: "b1", url: url), "不正パス混入は全破棄")
    }

    func testLoadRejectsUnsafePathsInHistory() throws {
        // 古い世代は逆差分のパスから組み立てられるので、restored / removed の両方も検証する（#128）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-log-unsafe-hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")
        let latest = ManifestGenerationLog.Generation(
            anchor: "g2", fetchedAt: Date(timeIntervalSince1970: 200),
            shardEtags: [:], files: ["ok.txt": entry(sha: "1")])
        for delta in [
            ManifestGenerationLog.ReverseDelta(
                anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
                restored: ["../escape.txt": entry(sha: "2")], removed: []),
            ManifestGenerationLog.ReverseDelta(
                anchor: "g1", fetchedAt: Date(timeIntervalSince1970: 100),
                restored: [:], removed: ["/abs.txt"]),
        ] {
            let tampered = ManifestGenerationLog.Payload(
                schemaVersion: ManifestGenerationLog.currentSchemaVersion, bucket: "b1",
                latest: latest, history: [delta])
            try ManifestGenerationLog.save(tampered, url: url)
            XCTAssertNil(ManifestGenerationLog.load(bucket: "b1", url: url), "逆差分の不正パスも全破棄")
        }
    }

    // MARK: - 差分保存（Issue #128）

    func testOldGenerationsAreReconstructedFromReverseDeltas() {
        // 追加・変更・削除が混ざった 4 世代を積み、どの anchor からも元のファイルマップが戻ること
        let maps: [[String: ManifestFileEntry]] = [
            ["a.txt": entry(sha: "1"), "b.txt": entry(sha: "1")],
            ["a.txt": entry(sha: "2"), "b.txt": entry(sha: "1"), "c.txt": entry(sha: "1")],
            ["a.txt": entry(sha: "2"), "c.txt": entry(sha: "2")],
            ["a.txt": entry(sha: "3"), "b.txt": entry(sha: "9"), "d/e.txt": entry(sha: "1")],
        ]
        var payload: ManifestGenerationLog.Payload?
        for (i, files) in maps.enumerated() {
            (payload, _) = ManifestGenerationLog.appending(
                snapshot: snapshot(files: files, etags: ["ab": "e\(i)"]),
                anchor: "g\(i)", fetchedAt: Date(timeIntervalSince1970: Double(i)),
                to: payload, bucket: "b1"
            )
        }
        XCTAssertEqual(payload?.anchors, ["g0", "g1", "g2", "g3"])
        for (i, files) in maps.enumerated() {
            let generation = ManifestGenerationLog.generation(anchor: "g\(i)", in: payload)
            XCTAssertEqual(generation?.files, files, "g\(i)")
            XCTAssertEqual(generation?.fetchedAt, Date(timeIntervalSince1970: Double(i)))
        }
        // shardEtags は最新世代だけが持つ（増分ロードの前回値）
        XCTAssertEqual(ManifestGenerationLog.latest(of: payload)?.shardEtags, ["ab": "e3"])
        XCTAssertEqual(ManifestGenerationLog.generation(anchor: "g0", in: payload)?.shardEtags, [:])
    }

    func testHistoryHoldsOnlyChangedEntries() {
        // 古い世代は全件を複製せず、変わったパスだけを持つ（135MB 肥大の再発防止）
        var files: [String: ManifestFileEntry] = [:]
        for i in 0..<100 { files["f\(i).txt"] = entry(sha: "1") }
        let (first, _) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: files), anchor: "g1",
            fetchedAt: Date(timeIntervalSince1970: 100), to: nil, bucket: "b1")
        files["f0.txt"] = entry(sha: "2")
        files["new.txt"] = entry(sha: "1")
        let (second, _) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: files), anchor: "g2",
            fetchedAt: Date(timeIntervalSince1970: 200), to: first, bucket: "b1")
        XCTAssertEqual(second.history.count, 1)
        XCTAssertEqual(second.history[0].restored, ["f0.txt": entry(sha: "1")])
        XCTAssertEqual(second.history[0].removed, ["new.txt"])
    }

    func testDecodeRejectsV1Payload() throws {
        // v1（世代ごとの全件複製）は読めない = cold 扱い（更新後に一度だけ全再列挙・ユーザ確定）
        let v1 = #"{"bucket":"b1","generations":[{"anchor":"g1","fetchedAt":"2026-10-16T00:00:00Z","files":{},"shardEtags":{}}],"schemaVersion":1}"#
        XCTAssertThrowsError(try ManifestGenerationLog.decode(Data(v1.utf8)))
    }

    func testV1LogOnDiskRecoversAsColdThenSavesV2() throws {
        // 回復経路（PR #129 レビュー N3）: v1 のファイルは load で nil（cold）→ 次の appending
        // （前回なし = 新世代）+ save で v2 が書かれ、以後は読める
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-log-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")
        let v1 = #"{"bucket":"b1","generations":[{"anchor":"g1","fetchedAt":"2026-10-16T00:00:00Z","files":{"a.txt":{"size":1,"mtime":"2026-07-04T00:00:00Z","sha256":"1","etag":"e","device_id":"d","uploaded_at":"2026-07-04T00:00:00Z"}},"shardEtags":{}}],"schemaVersion":1}"#
        try Data(v1.utf8).write(to: url)

        let loaded = ManifestGenerationLog.load(bucket: "b1", url: url)
        XCTAssertNil(loaded, "v1 は cold 扱い")
        let (payload, appended) = ManifestGenerationLog.appending(
            snapshot: snapshot(files: ["a.txt": entry(sha: "1")]),
            anchor: "g-new", fetchedAt: Date(timeIntervalSince1970: 100),
            to: loaded, bucket: "b1")
        XCTAssertTrue(appended, "cold からの新世代 = signal 契機")
        try ManifestGenerationLog.save(payload, url: url)
        let reloaded = ManifestGenerationLog.load(bucket: "b1", url: url)
        XCTAssertEqual(reloaded, payload)
        XCTAssertEqual(reloaded?.schemaVersion, 2)
    }

    func testLoadTruncatesOverlongHistory() throws {
        // 上限を超える history は古い側から切り詰め、残った世代は正しく組み立てられる（N2）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-log-long-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")
        var payload: ManifestGenerationLog.Payload?
        for i in 0..<6 {
            (payload, _) = ManifestGenerationLog.appending(
                snapshot: snapshot(files: ["a.txt": entry(sha: "\(i)")]),
                anchor: "g\(i)", fetchedAt: Date(timeIntervalSince1970: Double(i)),
                to: payload, bucket: "b1", maxGenerations: 6)
        }
        try ManifestGenerationLog.save(payload!, url: url)
        let loaded = ManifestGenerationLog.load(bucket: "b1", url: url, maxGenerations: 3)
        XCTAssertEqual(loaded?.anchors, ["g3", "g4", "g5"])
        XCTAssertEqual(
            ManifestGenerationLog.generation(anchor: "g3", in: loaded)?.files["a.txt"]?.sha256, "3")
        XCTAssertNil(ManifestGenerationLog.generation(anchor: "g2", in: loaded))
    }
}
