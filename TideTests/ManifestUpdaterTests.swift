import XCTest
import TideCore

/// `ManifestUpdater` の分岐 →「マニフェストを実際に書いたか」→ `onManifestDidWrite` 発火の
/// 配線を回帰固定する（M5 Phase 5-0）。発火は FP ドメインへの signal に直結するため、
/// 「書いていないのに発火（無駄 signal）」「書いたのに非発火（staleness 窓 = PR #51 レビュー #4）」の
/// 両方向を全分岐で固定する。
final class ManifestUpdaterTests: XCTestCase {
    /// @Sendable クロージャから加算できる発火カウンタ。
    private final class FireCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func makeEntry(sha: String, size: Int64 = 10) -> ManifestFileEntry {
        ManifestFileEntry(
            size: size,
            mtime: "2026-07-05T00:00:00Z",
            sha256: sha,
            s3VersionId: "v-\(sha)",
            etag: "obj-etag-\(sha)",
            deviceId: "test-device",
            uploadedAt: "2026-07-05T00:00:00Z"
        )
    }

    private func makeUpdater(
        store: InMemoryManifestStore, counter: FireCounter
    ) -> ManifestUpdater {
        ManifestUpdater(
            store: store,
            deviceId: "test-device",
            onManifestDidWrite: { counter.increment() }
        )
    }

    // MARK: - updateFileEntry

    /// .wrote（新規作成）→ 発火 1 回・シャードと index が更新される。
    func testWroteFiresHookOnce() async throws {
        let store = InMemoryManifestStore()
        let counter = FireCounter()
        let path = "docs/a.txt"
        let entry = makeEntry(sha: "aaa")

        let outcome = try await makeUpdater(store: store, counter: counter)
            .updateFileEntry(for: path, base: nil, newEntry: entry)

        XCTAssertEqual(outcome, .wrote)
        XCTAssertEqual(counter.count, 1)
        let shardId = ManifestSharding.shardId(for: path)
        let shard = await store.shards[shardId]
        XCTAssertEqual(shard?.files[path], entry)
        let index = await store.index
        XCTAssertEqual(index?.shards[shardId]?.count, 1)
    }

    /// .alreadyUpToDate（別書き手が同一内容を確定済み）→ 書かない・発火 0 回。
    func testAlreadyUpToDateDoesNotFire() async throws {
        let store = InMemoryManifestStore()
        let counter = FireCounter()
        let path = "docs/a.txt"
        let remote = makeEntry(sha: "same")
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = remote
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .updateFileEntry(for: path, base: "old-base", newEntry: makeEntry(sha: "same"))

        XCTAssertEqual(outcome, .alreadyUpToDate(remote))
        XCTAssertEqual(counter.count, 0)
        // シャードは元のまま（自分の entry で上書きしていない = s3VersionId 等が remote のまま）
        let stored = await store.shards[shardId]
        XCTAssertEqual(stored?.files[path], remote)
    }

    /// .conflict（base とも uploading とも違う sha が権威に居る）→ uploadConflict throw・発火 0 回。
    func testConflictDoesNotFireAndLeavesShardUntouched() async throws {
        let store = InMemoryManifestStore()
        let counter = FireCounter()
        let path = "docs/a.txt"
        let remote = makeEntry(sha: "theirs")
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = remote
        await store.seed(shard: shard)

        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: path, base: "base", newEntry: makeEntry(sha: "mine"))
            XCTFail("expected uploadConflict")
        } catch let SyncError.uploadConflict(conflictPath, remoteEntry) {
            XCTAssertEqual(conflictPath, path)
            XCTAssertEqual(remoteEntry, remote)
        }
        XCTAssertEqual(counter.count, 0)
        let stored = await store.shards[shardId]
        XCTAssertEqual(stored?.files[path], remote)
    }

    /// 412 → 再取得 → 成功のリトライ経路でも発火はちょうど 1 回。
    func test412RetryThenSuccessFiresOnce() async throws {
        let store = InMemoryManifestStore()
        let counter = FireCounter()
        let path = "docs/a.txt"
        await store.failNextPutShard(times: 1)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .updateFileEntry(for: path, base: nil, newEntry: makeEntry(sha: "aaa"))

        XCTAssertEqual(outcome, .wrote)
        XCTAssertEqual(counter.count, 1)
    }

    /// 412 がリトライ上限（5 回）まで続く → manifestUpdateFailed・発火 0 回。
    func test412ExhaustedDoesNotFire() async throws {
        let store = InMemoryManifestStore()
        let counter = FireCounter()
        await store.failNextPutShard(times: 5)

        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: "docs/a.txt", base: nil, newEntry: makeEntry(sha: "aaa"))
            XCTFail("expected manifestUpdateFailed")
        } catch let SyncError.manifestUpdateFailed(message) {
            XCTAssertTrue(message.contains("conditional update failed"))
        }
        XCTAssertEqual(counter.count, 0)
    }

    // MARK: - updateShard（削除経路）

    /// 削除で残エントリありのシャード書換 → 発火 1 回。
    func testUpdateShardRemovalFiresOnce() async throws {
        let store = InMemoryManifestStore()
        let counter = FireCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeEntry(sha: "aaa")
        shard.files[path + ".keep"] = makeEntry(sha: "bbb")
        await store.seed(shard: shard)

        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: path)
        }

        XCTAssertEqual(counter.count, 1)
        let stored = await store.shards[shardId]
        XCTAssertNil(stored?.files[path])
        XCTAssertNotNil(stored?.files[path + ".keep"])
    }

    /// 最後の 1 件を消して空シャード削除になる経路でも発火 1 回・index から shard が消える。
    func testUpdateShardEmptyDeletionFiresOnce() async throws {
        let store = InMemoryManifestStore()
        let counter = FireCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeEntry(sha: "aaa")
        await store.seed(shard: shard)

        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: path)
        }

        XCTAssertEqual(counter.count, 1)
        let stored = await store.shards[shardId]
        XCTAssertNil(stored)
        let index = await store.index
        XCTAssertNil(index?.shards[shardId])
    }

    /// hook 未設定（nil）でも全経路が従来どおり成功する（後方互換）。
    func testNilHookStillWrites() async throws {
        let store = InMemoryManifestStore()
        let updater = ManifestUpdater(store: store, deviceId: "test-device")

        let outcome = try await updater.updateFileEntry(
            for: "docs/a.txt", base: nil, newEntry: makeEntry(sha: "aaa")
        )
        XCTAssertEqual(outcome, .wrote)
    }
}
