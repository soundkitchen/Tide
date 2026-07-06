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
        private var _indexFetchCount = 0
        /// getIndex が呼ばれた回数（バースト床・短絡の検証用）。
        var indexFetchCount: Int { lock.withLock { _indexFetchCount } }

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

        // stale ロード破棄（M5 Phase 5-2）検証用のゲート: armGate() 後の次の getIndex を
        // openGate() まで停止させ、「ロード開始 → 書込 → ロード完了」の順序を決定的に作る。
        private var _gateArmed = false
        private var _gateWaiter: CheckedContinuation<Void, Never>?
        var gateWaiting: Bool { lock.withLock { _gateWaiter != nil } }
        func armGate() { lock.withLock { _gateArmed = true } }
        func openGate() {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let w = _gateWaiter
                _gateWaiter = nil
                _gateArmed = false
                return w
            }
            waiter?.resume()
        }

        func getIndex() async throws -> TideS3Client.ManifestFetch<ManifestIndex>? {
            let shouldWait = lock.withLock { _gateArmed && _gateWaiter == nil }
            if shouldWait {
                await withCheckedContinuation { cont in
                    lock.withLock { _gateWaiter = cont }
                }
            }
            let (files, version) = lock.withLock {
                _indexFetchCount += 1
                return (_files, _version)
            }
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

    // SignalCounter は TestSupport の共有版を使う（PR #56 レビュー ⑦で吊り上げ）。

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
        let second = try await cache.refreshedCurrent(callerAnchor: first.anchor)
        XCTAssertNotEqual(second.anchor, first.anchor)
        XCTAssertEqual(second.tree.node(at: "new.txt")?.isDirectory, false)
        XCTAssertEqual(signals.count, 2)

        // 旧 anchor の世代は diff の起点としてまだ引ける
        let origin = await cache.generation(anchor: first.anchor)
        XCTAssertEqual(origin?.files["a.txt"]?.sha256, "1")
        XCTAssertNil(origin?.files["new.txt"])
    }

    func testRefreshedCurrentBypassesFloorWhenCallerAnchorMatches() async throws {
        // PR #51 レビュー #1: 直近ロード（床内）が signal 前の変更前ツリーでも、呼び出し元と
        // 同じ anchor なら「変更なし」と誤答せず必ず再ロードすること。
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: nil,
            maxAge: 3600, minRefreshInterval: 3600  // 床を大きくして「握り潰し」条件を再現
        )
        let first = try await cache.current()

        // リモート変更直後（床内）に signal 応答が来たケース
        source.set(files: ["a.txt": entry(sha: "2")])
        let second = try await cache.refreshedCurrent(callerAnchor: first.anchor)
        XCTAssertNotEqual(second.anchor, first.anchor, "床を無視して再ロードし新世代を返す")

        // バースト吸収は生きている: 旧 anchor（キャッシュと異なる世代）からの後続 enumerateChanges は
        // 床内ならキャッシュから diff 材料を返し、追加の index GET をしない
        let before = source.indexFetchCount
        let third = try await cache.refreshedCurrent(callerAnchor: first.anchor)
        XCTAssertEqual(third.anchor, second.anchor)
        XCTAssertEqual(source.indexFetchCount, before, "異世代 anchor への床は追加 GET なし")
    }

    func testUnchangedRefreshDoesNotRewriteLogFile() async throws {
        // PR #51 レビュー #5: 無変化リフレッシュで世代ログを全量再書込みしない
        let url = try tempLogURL()
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: url,
            maxAge: 0, minRefreshInterval: 0
        )
        _ = try await cache.current()
        let bytesAfterFirst = try Data(contentsOf: url)

        _ = try await cache.current()  // maxAge 0 = 再リフレッシュ（無変化）
        XCTAssertEqual(try Data(contentsOf: url), bytesAfterFirst, "無変化なら書き直さない")

        source.set(files: ["a.txt": entry(sha: "2")])
        _ = try await cache.current()
        XCTAssertNotEqual(try Data(contentsOf: url), bytesAfterFirst, "変化したら書く")
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

    // MARK: - 自世代 append（recordLocalChange・M5 Phase 5-2）

    /// 拡張自身の書込の即時反映: anchor 前進・ツリー反映・onNewGeneration 発火・永続化。
    func testRecordLocalChangeAdvancesAnchorAndFires() async throws {
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let signals = SignalCounter()
        let logURL = try tempLogURL()
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: logURL,
            maxAge: 3600, onNewGeneration: { signals.fire() }
        )
        let gen1 = try await cache.current()
        let n0 = signals.count

        let w = entry(sha: "w1")
        await cache.recordLocalChange(
            updatingShardEtags: [ManifestSharding.shardId(for: "w.txt"): "w-etag"]
        ) { $0["w.txt"] = w }

        // TTL 内の current() はロードせずキャッシュ = 書込済みツリーが即時に見える
        let after = try await cache.current()
        XCTAssertNotEqual(after.anchor, gen1.anchor)
        XCTAssertNotNil(after.tree.node(at: "w.txt"))
        XCTAssertEqual(signals.count, n0 + 1)
        // 両世代とも anchor 解決できる（enumerateChanges の diff 起点に使える）
        let g1 = await cache.generation(anchor: gen1.anchor)
        XCTAssertNotNil(g1)
        let g2 = await cache.generation(anchor: after.anchor)
        XCTAssertNotNil(g2)
        // 永続化: 別インスタンス（プロセス再起動相当）からも自世代が引ける
        let cache2 = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: logURL
        )
        let g2b = await cache2.generation(anchor: after.anchor)
        XCTAssertNotNil(g2b)
    }

    /// stale ロード破棄: 書込（recordLocalChange）より前に開始した S3 ロードの結果を世代化しない
    /// （巻き戻り世代 = 旧 entry の didUpdate = 実 bounce の防止）。破棄後に一度だけ読み直す。
    func testStaleLoadStartedBeforeLocalWriteIsDiscarded() async throws {
        let source = MutableSource(files: ["a.txt": entry(sha: "1")])
        let cache = ManifestGenerationCache(
            loader: ManifestSnapshotLoader(source: source), bucket: "b", logURL: nil,
            maxAge: 3600, minRefreshInterval: 0
        )
        let gen1 = try await cache.current()

        // ロードを getIndex で停止させてから、書込を挟む
        source.armGate()
        let task = Task { try await cache.refreshedCurrent(callerAnchor: gen1.anchor) }
        while !source.gateWaiting {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let w = entry(sha: "w1")
        await cache.recordLocalChange(
            updatingShardEtags: [ManifestSharding.shardId(for: "w.txt"): "v1"]
        ) { $0["w.txt"] = w }
        let localAnchor = try await cache.current().anchor
        // 書込は S3（source）にも実在する（実運用では putShard/updateIndex 済みの状態）
        source.set(files: ["a.txt": entry(sha: "1"), "w.txt": w])
        source.openGate()

        let result = try await task.value
        // 書込前開始のロード（w.txt を含まない）が世代化されず、読み直しで w.txt が残る
        XCTAssertNotNil(result.tree.node(at: "w.txt"))
        XCTAssertEqual(result.anchor, localAnchor)  // 巻き戻り世代を作っていない
    }
}
