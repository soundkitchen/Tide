import XCTest
import TideCore
@testable import Tide

/// 世代キャッシュ（M5 Phase 4・File Provider 拡張の心臓部）。
/// TTL / 世代確定 / anchor 解決 / onNewGeneration（機会的自己 signal の契機）/ 永続復元を固定する。
final class ManifestGenerationCacheTests: XCTestCase {
    private final class MutableSource: ManifestSnapshotSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _files: [String: ManifestFileEntry]
        private var _version = 0

        init(files: [String: ManifestFileEntry]) {
            self._files = files
        }

        /// リモートの内容を差し替える（etag はバージョン番号で前進）
        func set(files: [String: ManifestFileEntry]) {
            lock.withLock {
                _files = files
                _version += 1
            }
        }

        func getIndex() async throws -> TideS3Client.ManifestFetch<ManifestIndex>? {
            let (files, version) = lock.withLock { (_files, _version) }
            var shards: [String: ManifestIndex.ShardInfo] = [:]
            for path in files.keys {
                shards[ManifestSharding.shardId(for: path)] = ManifestIndex.ShardInfo(etag: "v\(version)", count: 1)
            }
            return TideS3Client.ManifestFetch(
                value: ManifestIndex(updatedAt: "2026-07-04T00:00:00Z", updatedBy: "test", shards: shards),
                etag: "idx-v\(version)"
            )
        }

        func getShard(_ id: String) async throws -> TideS3Client.ManifestFetch<ManifestShard>? {
            let (files, version) = lock.withLock { (_files, _version) }
            let shardFiles = files.filter { ManifestSharding.shardId(for: $0.key) == id }
            guard !shardFiles.isEmpty else { return nil }
            return TideS3Client.ManifestFetch(
                value: ManifestShard(shardId: id, updatedAt: "2026-07-04T00:00:00Z", files: shardFiles),
                etag: "v\(version)"
            )
        }
    }

    private final class SignalCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func fire() { lock.withLock { _count += 1 } }
    }

    private func entry(sha: String, mtime: String = "2026-07-01T00:00:00Z") -> ManifestFileEntry {
        ManifestFileEntry(
            size: 1, mtime: mtime, sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: mtime
        )
    }

    private func tempLogURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("log.json")
    }

    func testCurrentServesTreeAndStableAnchorWithinTTL() async throws {
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: nil, maxAge: 3600
        )
        let first = try await cache.current()
        XCTAssertEqual(first.tree.node(at: "a.txt")?.isDirectory, false)
        XCTAssertFalse(first.anchor.isEmpty)

        // TTL 内はリモートが変わっても同じ世代（リフレッシュしない）
        source.set(files: ["a.txt": entry(sha: "2")])
        let second = try await cache.current()
        XCTAssertEqual(second.anchor, first.anchor)
    }

    func testUnchangedRefreshKeepsAnchorAndDoesNotSignal() async throws {
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let signals = SignalCounter()
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: nil,
            maxAge: 0, minRefreshInterval: 0, onNewGeneration: { signals.fire() }
        )
        let first = try await cache.current()
        XCTAssertEqual(signals.count, 1, "cold ロードは新世代 = signal 1 回")

        let second = try await cache.current()  // maxAge 0 = 毎回リフレッシュ
        XCTAssertEqual(second.anchor, first.anchor, "無変化なら anchor 安定")
        XCTAssertEqual(signals.count, 1, "無変化リフレッシュでは signal しない")
    }

    func testChangedRemoteAppendsGenerationAndSignals() async throws {
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let signals = SignalCounter()
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: nil,
            maxAge: 0, minRefreshInterval: 0, onNewGeneration: { signals.fire() }
        )
        let first = try await cache.current()

        source.set(files: ["a.txt": entry(sha: "2"), "new.txt": entry(sha: "3")])
        let second = try await cache.refreshedCurrent()
        XCTAssertNotEqual(second.anchor, first.anchor)
        XCTAssertEqual(second.tree.node(at: "new.txt")?.isDirectory, false)
        XCTAssertEqual(signals.count, 2)

        // 旧 anchor の世代は diff の起点としてまだ引ける
        let origin = await cache.generation(anchor: first.anchor)
        XCTAssertEqual(origin?.files["a.txt"]?.sha256, "1")
        XCTAssertNil(origin?.files["new.txt"])
    }

    func testUnknownAnchorResolvesNil() async throws {
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: nil
        )
        _ = try await cache.current()
        let gen = await cache.generation(anchor: "tide-poc-static")
        XCTAssertNil(gen, "Phase 3 の静的 anchor は未知 = syncAnchorExpired 行き")
    }

    func testPersistedLogSurvivesProcessRestart() async throws {
        let url = try tempLogURL()
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let cache1 = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: url,
            maxAge: 0, minRefreshInterval: 0
        )
        let first = try await cache1.current()

        // プロセス再起動を模擬: 新しいキャッシュインスタンスがログから世代を復元し、
        // 旧 anchor を diff の起点として解決できる
        let cache2 = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: url
        )
        let origin = await cache2.generation(anchor: first.anchor)
        XCTAssertEqual(origin?.files["a.txt"]?.sha256, "1")

        // 復元された前世代を起点に増分ロードが働き、無変化なら anchor も維持される
        let current = try await cache2.current()
        XCTAssertEqual(current.anchor, first.anchor)
    }

    func testBucketMismatchLogIsIgnored() async throws {
        let url = try tempLogURL()
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let cache1 = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b1", logURL: url
        )
        let first = try await cache1.current()

        // 別バケットのキャッシュはログを無視して cold スタート（旧 anchor は解決不能）
        let cache2 = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b2", logURL: url
        )
        let gen = await cache2.generation(anchor: first.anchor)
        XCTAssertNil(gen)
    }
}
