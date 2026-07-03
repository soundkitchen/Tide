import XCTest
import TideCore
@testable import Tide

/// DB 非依存の全シャード読みローダ（M5 Phase 3・File Provider 拡張用）。
final class ManifestSnapshotLoaderTests: XCTestCase {
    private struct FakeSource: ManifestSnapshotSource {
        var index: ManifestIndex?
        var shards: [String: ManifestShard]

        func getIndex() async throws -> TideS3Client.ManifestFetch<ManifestIndex>? {
            index.map { TideS3Client.ManifestFetch(value: $0, etag: "idx") }
        }

        func getShard(_ id: String) async throws -> TideS3Client.ManifestFetch<ManifestShard>? {
            shards[id].map { TideS3Client.ManifestFetch(value: $0, etag: "e-\(id)") }
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
}
