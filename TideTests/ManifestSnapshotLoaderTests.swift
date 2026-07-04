import XCTest
import TideCore
@testable import Tide

/// DB 非依存の全シャード読みローダ（M5 Phase 3・File Provider 拡張用）。
final class ManifestSnapshotLoaderTests: XCTestCase {
    private final class FakeSource: ManifestSnapshotSource, @unchecked Sendable {
        var index: ManifestIndex?
        var shards: [String: ManifestShard]
        private let lock = NSLock()
        private var _fetchedShardIds: [String] = []
        /// getShard が実際に呼ばれた shardId（増分ロードのスキップ検証用）。
        var fetchedShardIds: [String] {
            lock.withLock { _fetchedShardIds }
        }

        init(index: ManifestIndex?, shards: [String: ManifestShard]) {
            self.index = index
            self.shards = shards
        }

        func getIndex() async throws -> TideS3Client.ManifestFetch<ManifestIndex>? {
            index.map { TideS3Client.ManifestFetch(value: $0, etag: "idx") }
        }

        func getShard(_ id: String) async throws -> TideS3Client.ManifestFetch<ManifestShard>? {
            lock.withLock { _fetchedShardIds.append(id) }
            return shards[id].map { TideS3Client.ManifestFetch(value: $0, etag: "e-\(id)") }
        }
    }

    private func entry(sha: String) -> ManifestFileEntry {
        ManifestFileEntry(
            size: 1, mtime: "2026-07-03T00:00:00Z", sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: "2026-07-03T00:00:00Z"
        )
    }

    private func index(shardIds: [String]) -> ManifestIndex {
        ManifestIndex(
            updatedAt: "2026-07-03T00:00:00Z", updatedBy: "test",
            shards: Dictionary(uniqueKeysWithValues: shardIds.map {
                ($0, ManifestIndex.ShardInfo(etag: "e-\($0)", count: 1))
            })
        )
    }

    private func shard(_ id: String, files: [String: ManifestFileEntry]) -> ManifestShard {
        ManifestShard(shardId: id, updatedAt: "2026-07-03T00:00:00Z", files: files)
    }

    func testNoIndexReturnsEmpty() async throws {
        let loader = ManifestSnapshotLoader(source: FakeSource(index: nil, shards: [:]))
        let files = try await loader.load()
        XCTAssertTrue(files.isEmpty)
    }

    func testMergesAllShards() async throws {
        let source = FakeSource(
            index: index(shardIds: ["ab", "cd"]),
            shards: [
                "ab": shard("ab", files: ["a.txt": entry(sha: "1")]),
                "cd": shard("cd", files: ["docs/b.txt": entry(sha: "2")]),
            ]
        )
        let files = try await ManifestSnapshotLoader(source: source).load()
        XCTAssertEqual(Set(files.keys), ["a.txt", "docs/b.txt"])
        XCTAssertEqual(files["a.txt"]?.sha256, "1")
    }

    func testRejectsInvalidShardId() async throws {
        // 不正 shardId（S3 キー組み立て前のゲート）は取得対象から除外される
        let source = FakeSource(
            index: index(shardIds: ["ab", "../evil", "ZZ"]),
            shards: [
                "ab": shard("ab", files: ["ok.txt": entry(sha: "1")]),
                "../evil": shard("xx", files: ["evil.txt": entry(sha: "2")]),
                "ZZ": shard("ZZ", files: ["upper.txt": entry(sha: "3")]),
            ]
        )
        let files = try await ManifestSnapshotLoader(source: source).load()
        XCTAssertEqual(Set(files.keys), ["ok.txt"])
    }

    func testRejectsUnsafePaths() async throws {
        // 不正パス（トラバーサル・絶対パス）は取り込み前に捨てる
        let source = FakeSource(
            index: index(shardIds: ["ab"]),
            shards: [
                "ab": shard("ab", files: [
                    "ok.txt": entry(sha: "1"),
                    "../escape.txt": entry(sha: "2"),
                    "/etc/passwd": entry(sha: "3"),
                ]),
            ]
        )
        let files = try await ManifestSnapshotLoader(source: source).load()
        XCTAssertEqual(Set(files.keys), ["ok.txt"])
    }

    func testCollectsAllShardsBeyondParallelismLimit() async throws {
        // 並列上限（8）を大きく超えるシャード数でも全件回収されること。
        // 旧実装は上限到達時の group.next() 結果を捨てており、シャード数 > 8 で
        // ファイルが黙って欠落した（Phase 3 実機で 15 ファイル中 6 件欠落）。回帰固定。
        let shardIds = (0..<32).map { String(format: "%02x", $0) }
        var shards: [String: ManifestShard] = [:]
        for id in shardIds {
            shards[id] = shard(id, files: ["file-\(id).txt": entry(sha: id)])
        }
        let source = FakeSource(index: index(shardIds: shardIds), shards: shards)

        let files = try await ManifestSnapshotLoader(source: source).load()

        XCTAssertEqual(files.count, 32)
        XCTAssertEqual(Set(files.keys), Set(shardIds.map { "file-\($0).txt" }))
    }

    func testMissingShardIsSkipped() async throws {
        // index にはあるが 404（削除レース）のシャードはスキップして残りを返す
        let source = FakeSource(
            index: index(shardIds: ["ab", "cd"]),
            shards: ["ab": shard("ab", files: ["a.txt": entry(sha: "1")])]
        )
        let files = try await ManifestSnapshotLoader(source: source).load()
        XCTAssertEqual(Set(files.keys), ["a.txt"])
    }

    // MARK: - 増分ロード（M5 Phase 4）

    /// パスの正規シャード（`ManifestSharding.shardId(for:)`）に置いた fixture を組む。
    /// 増分ロードの持ち越しはパスからシャード ID を再計算するため、正規配置が前提。
    private func canonicalSource(files: [String: ManifestFileEntry]) -> FakeSource {
        var shards: [String: ManifestShard] = [:]
        for (path, entry) in files {
            let sid = ManifestSharding.shardId(for: path)
            var files = shards[sid]?.files ?? [:]
            files[path] = entry
            shards[sid] = shard(sid, files: files)
        }
        return FakeSource(index: index(shardIds: Array(shards.keys)), shards: shards)
    }

    func testIncrementalColdLoadEqualsFullLoad() async throws {
        let source = canonicalSource(files: [
            "a.txt": entry(sha: "1"), "docs/b.txt": entry(sha: "2"),
        ])
        let result = try await ManifestSnapshotLoader(source: source).load(previous: nil)
        XCTAssertEqual(Set(result.files.keys), ["a.txt", "docs/b.txt"])
        // 取得したシャードの etag が全件記録される（次回の増分判定の材料）
        XCTAssertEqual(
            Set(result.shardEtags.keys),
            Set(["a.txt", "docs/b.txt"].map { ManifestSharding.shardId(for: $0) })
        )
    }

    func testIncrementalSkipsUnchangedShards() async throws {
        let source = canonicalSource(files: [
            "a.txt": entry(sha: "1"), "docs/b.txt": entry(sha: "2"),
        ])
        let loader = ManifestSnapshotLoader(source: source)
        let first = try await loader.load(previous: nil)
        let fetchedInFirst = source.fetchedShardIds.count

        // 無変化の再ロード: シャード GET はゼロ・ファイルは持ち越し
        let second = try await loader.load(previous: first)
        XCTAssertEqual(source.fetchedShardIds.count, fetchedInFirst, "無変化シャードを再取得しない")
        XCTAssertEqual(second, first)
    }

    func testIncrementalFetchesOnlyChangedShard() async throws {
        let source = canonicalSource(files: [
            "a.txt": entry(sha: "1"), "docs/b.txt": entry(sha: "2"),
        ])
        let loader = ManifestSnapshotLoader(source: source)
        let first = try await loader.load(previous: nil)

        // a.txt のシャードだけ内容と index 宣言 etag を進める（b 側は元の宣言値のまま）
        let sidA = ManifestSharding.shardId(for: "a.txt")
        let sidB = ManifestSharding.shardId(for: "docs/b.txt")
        source.shards[sidA] = shard(sidA, files: ["a.txt": entry(sha: "1-updated")])
        source.index = ManifestIndex(
            updatedAt: "2026-07-04T00:00:00Z", updatedBy: "test",
            shards: [
                sidA: ManifestIndex.ShardInfo(etag: "e-new", count: 1),
                sidB: ManifestIndex.ShardInfo(etag: "e-\(sidB)", count: 1),
            ]
        )

        let before = source.fetchedShardIds.count
        let second = try await loader.load(previous: first)
        XCTAssertEqual(source.fetchedShardIds.suffix(from: before).sorted(), [sidA], "変化したシャードのみ取得")
        XCTAssertEqual(second.files["a.txt"]?.sha256, "1-updated")
        XCTAssertEqual(second.files["docs/b.txt"]?.sha256, "2", "無変化シャードの持ち越し")
    }

    func testIncrementalDropsFilesOfRemovedShard() async throws {
        let source = canonicalSource(files: [
            "a.txt": entry(sha: "1"), "docs/b.txt": entry(sha: "2"),
        ])
        let loader = ManifestSnapshotLoader(source: source)
        let first = try await loader.load(previous: nil)

        // a.txt のシャードを index から除去（= 配下全削除）
        let sidA = ManifestSharding.shardId(for: "a.txt")
        let sidB = ManifestSharding.shardId(for: "docs/b.txt")
        source.shards[sidA] = nil
        source.index = index(shardIds: [sidB])

        let second = try await loader.load(previous: first)
        XCTAssertEqual(Set(second.files.keys), ["docs/b.txt"], "消えたシャードのファイルは脱落")
        XCTAssertEqual(Set(second.shardEtags.keys), [sidB], "消えたシャードの etag も脱落")
    }

    func testIncrementalMissingShardIsNotRecorded() async throws {
        // index にはあるが GET が 404（削除レース）のシャードは etag を記録しない＝次回再取得
        let source = canonicalSource(files: [
            "a.txt": entry(sha: "1"), "docs/b.txt": entry(sha: "2"),
        ])
        let sidA = ManifestSharding.shardId(for: "a.txt")
        source.shards[sidA] = nil  // index には残したまま GET だけ 404

        let result = try await ManifestSnapshotLoader(source: source).load(previous: nil)
        XCTAssertEqual(Set(result.files.keys), ["docs/b.txt"])
        XCTAssertNil(result.shardEtags[sidA])
    }
}
