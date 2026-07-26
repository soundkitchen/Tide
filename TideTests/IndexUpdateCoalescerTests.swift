import XCTest
import TideCore

/// `IndexUpdateCoalescer` の畳み込み・per-caller 返値・バッチ失敗伝播を回帰固定する（Issue #91）。
/// バッチ構成はストアの getIndex ゲート（`holdNextGetIndex`）で決定的に作る:
/// flush 1 が getIndex で停止している間に積んだ submit は必ず次の flush に束ねられる。
final class IndexUpdateCoalescerTests: XCTestCase {
    private static let fastPolicy = ConditionalRetryPolicy(
        attempts: ConditionalRetryPolicy.index.attempts, baseDelayNanos: 0, maxDelayNanos: 0
    )

    private func makeCoalescer(store: InMemoryManifestStore) -> IndexUpdateCoalescer {
        IndexUpdateCoalescer(store: store, deviceId: "test-device", policy: Self.fastPolicy)
    }

    /// 条件成立までポーリング（ゲート到達・pending 積み上がりの同期観測用）。
    private func waitUntil(
        _ label: String, timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timeout waiting for: \(label)")
    }

    /// flush in-flight 中に届いた submit は次の flush に束ねられ、putIndex は 2 回で済む
    /// （3 submit → flush1 = [t1] + flush2 = [t2, t3]）。全員が自分の commit を await して true。
    func testCoalescesPendingSubmitsIntoFewerPuts() async throws {
        let store = InMemoryManifestStore()
        let coalescer = makeCoalescer(store: store)
        await store.holdNextGetIndex()

        let t1 = Task {
            try await coalescer.submit { idx in
                idx.shards["aa"] = .init(etag: "e-a", count: 1)
                return true
            }
        }
        try await waitUntil("flush1 held at getIndex") { await store.isGetIndexHeld }

        let t2 = Task {
            try await coalescer.submit { idx in
                idx.shards["bb"] = .init(etag: "e-b", count: 2)
                return true
            }
        }
        let t3 = Task {
            try await coalescer.submit { idx in
                idx.shards["cc"] = .init(etag: "e-c", count: 3)
                return true
            }
        }
        try await waitUntil("t2/t3 pending") { await coalescer.pendingCount == 2 }
        await store.releaseHeldGetIndex()

        let r1 = try await t1.value
        let r2 = try await t2.value
        let r3 = try await t3.value
        XCTAssertTrue(r1 && r2 && r3)
        let putCount = await store.putIndexCount
        XCTAssertEqual(putCount, 2)  // 3 submit → 2 PUT（t2 + t3 が畳まれた）
        let index = await store.index
        XCTAssertEqual(index?.shards["aa"]?.etag, "e-a")
        XCTAssertEqual(index?.shards["bb"]?.etag, "e-b")
        XCTAssertEqual(index?.shards["cc"]?.etag, "e-c")
    }

    /// CAS 中止（transform が false）は per-caller: 同一バッチ内でも false の呼び出しには
    /// false が返り、その宣言は書かれない。true の呼び出しの書込は成立する。
    func testPerCallerCASAbortWithinBatch() async throws {
        let store = InMemoryManifestStore()
        let coalescer = makeCoalescer(store: store)
        await store.holdNextGetIndex()

        let t1 = Task {
            try await coalescer.submit { idx in
                idx.shards["aa"] = .init(etag: "e-a", count: 1)
                return true
            }
        }
        try await waitUntil("flush1 held at getIndex") { await store.isGetIndexHeld }

        let aborting = Task {
            try await coalescer.submit { _ in false }  // CAS 中止（観測条件不成立のモデル）
        }
        let writing = Task {
            try await coalescer.submit { idx in
                idx.shards["cc"] = .init(etag: "e-c", count: 3)
                return true
            }
        }
        try await waitUntil("batch2 pending") { await coalescer.pendingCount == 2 }
        await store.releaseHeldGetIndex()

        let r1 = try await t1.value
        let rAbort = try await aborting.value
        let rWrite = try await writing.value
        XCTAssertTrue(r1)
        XCTAssertFalse(rAbort)
        XCTAssertTrue(rWrite)
        let putCount = await store.putIndexCount
        XCTAssertEqual(putCount, 2)
    }

    /// リトライ枯渇はバッチ全員へ `manifestUpdateFailed` として伝播する
    /// （flush1 = t1 が 8 回・flush2 = t2+t3 が 8 回を消費して両バッチとも枯渇）。
    func testExhaustionPropagatesToAllBatchMembers() async throws {
        let store = InMemoryManifestStore()
        let coalescer = makeCoalescer(store: store)
        await store.holdNextGetIndex()

        let t1 = Task {
            try await coalescer.submit { idx in
                idx.shards["aa"] = .init(etag: "e-a", count: 1)
                return true
            }
        }
        try await waitUntil("flush1 held at getIndex") { await store.isGetIndexHeld }

        let t2 = Task {
            try await coalescer.submit { idx in
                idx.shards["bb"] = .init(etag: "e-b", count: 2)
                return true
            }
        }
        let t3 = Task {
            try await coalescer.submit { idx in
                idx.shards["cc"] = .init(etag: "e-c", count: 3)
                return true
            }
        }
        try await waitUntil("t2/t3 pending") { await coalescer.pendingCount == 2 }
        let attempts = Self.fastPolicy.attempts
        await store.failNextPutIndex(times: attempts * 2)
        await store.releaseHeldGetIndex()

        for task in [t1, t2, t3] {
            do {
                _ = try await task.value
                XCTFail("expected manifestUpdateFailed")
            } catch SyncError.manifestUpdateFailed {}
        }
        let putCount = await store.putIndexCount
        XCTAssertEqual(putCount, attempts * 2)
        let index = await store.index
        XCTAssertNil(index?.shards["aa"])
    }

    /// ManifestUpdater 経由のバースト（並行 updateFileEntry × 20・全て別シャード）が
    /// 全件成功し、index に全シャードが宣言され、発火は書込ごとに 1 回ずつ乗る。
    /// （コアレス前は同一プロセス内の putIndex CAS 競合が 412 リトライを消費していた形。）
    func testManifestUpdaterConcurrentBurstAllSucceed() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let updater = ManifestUpdater(
            store: store,
            deviceId: "test-device",
            onManifestDidWrite: { counter.fire() },
            shardRetryPolicy: ManifestUpdaterTests.fastShardPolicy,
            indexRetryPolicy: ManifestUpdaterTests.fastIndexPolicy
        )
        // 全て別シャードになるパスを 20 本集める（シャード内 CAS 競合を混ぜず index 側だけを見る）
        var paths: [String] = []
        var usedShards = Set<String>()
        var i = 0
        while paths.count < 20 {
            let p = "burst/f\(i).txt"
            let s = ManifestSharding.shardId(for: p)
            if usedShards.insert(s).inserted { paths.append(p) }
            i += 1
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask {
                    let outcome = try await updater.updateFileEntry(
                        for: path, base: nil, newEntry: makeManifestEntry(sha: "sha-\(path)")
                    )
                    guard case .wrote = outcome else {
                        return XCTFail("expected .wrote for \(path), got \(outcome)")
                    }
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(counter.count, 20)
        let index = await store.index
        for path in paths {
            let shardId = ManifestSharding.shardId(for: path)
            XCTAssertNotNil(index?.shards[shardId], "index missing declaration for \(shardId)")
        }
    }
}
