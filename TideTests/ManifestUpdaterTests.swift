import XCTest
import TideCore

/// `ManifestUpdater` の分岐 →「マニフェストを実際に書いたか」→ `onManifestDidWrite` 発火の
/// 配線を回帰固定する（M5 Phase 5-0）。発火は FP ドメインへの signal に直結するため、
/// 「書いていないのに発火（無駄 signal）」「書いたのに非発火（staleness 窓 = PR #51 レビュー #4）」の
/// 両方向を全分岐で固定する。PR #56 レビューで追加:
/// - ①: updateIndex リトライ尽きが「静かな成功」に化けず失敗として伝播し、
///   再試行の `.alreadyUpToDate` / no-op 再入が index を突合修復して発火する
/// - ②: no-op 削除（マニフェスト不在パスの delete）は書かない・発火しない
final class ManifestUpdaterTests: XCTestCase {
    private func makeUpdater(
        store: InMemoryManifestStore, counter: SignalCounter
    ) -> ManifestUpdater {
        ManifestUpdater(
            store: store,
            deviceId: "test-device",
            onManifestDidWrite: { counter.fire() }
        )
    }

    // MARK: - updateFileEntry

    /// .wrote（新規作成）→ 発火 1 回・シャードと index が更新される。
    func testWroteFiresHookOnce() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let entry = makeManifestEntry(sha: "aaa")

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

    /// .alreadyUpToDate（別書き手が同一内容を確定済み・index も整合）→ 書かない・発火 0 回。
    func testAlreadyUpToDateDoesNotFire() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let remote = makeManifestEntry(sha: "same")
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = remote
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .updateFileEntry(for: path, base: "old-base", newEntry: makeManifestEntry(sha: "same"))

        XCTAssertEqual(outcome, .alreadyUpToDate(remote))
        XCTAssertEqual(counter.count, 0)
        // シャードは元のまま（自分の entry で上書きしていない = s3VersionId 等が remote のまま）
        let stored = await store.shards[shardId]
        XCTAssertEqual(stored?.files[path], remote)
    }

    /// .conflict（base とも uploading とも違う sha が権威に居る）→ uploadConflict throw・発火 0 回。
    func testConflictDoesNotFireAndLeavesShardUntouched() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let remote = makeManifestEntry(sha: "theirs")
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = remote
        await store.seed(shard: shard)

        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: path, base: "base", newEntry: makeManifestEntry(sha: "mine"))
            XCTFail("expected uploadConflict")
        } catch let SyncError.uploadConflict(conflictPath, remoteEntry) {
            XCTAssertEqual(conflictPath, path)
            XCTAssertEqual(remoteEntry, remote)
        }
        XCTAssertEqual(counter.count, 0)
        let stored = await store.shards[shardId]
        XCTAssertEqual(stored?.files[path], remote)
    }

    /// パスに "412" を含む uploadConflict が外側リトライに「リトライ可能な 412」と誤分類されて
    /// 飲み込まれない（PR #56 レビュー ①: SyncError はクラシファイアに再マッチさせず素通し。
    /// String(describing:) ベースの分類は description に埋まる path/下位エラー文字列を拾ってしまう）。
    func testUploadConflictWith412LookalikePathPropagates() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/file-412.txt"
        let remote = makeManifestEntry(sha: "theirs")
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = remote
        await store.seed(shard: shard)

        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: path, base: "base", newEntry: makeManifestEntry(sha: "mine"))
            XCTFail("expected uploadConflict")
        } catch SyncError.uploadConflict {
            // ok: manifestUpdateFailed（5 回消費）へ化けないこと
        }
        XCTAssertEqual(counter.count, 0)
    }

    /// 412 → 再取得 → 成功のリトライ経路でも発火はちょうど 1 回。
    func test412RetryThenSuccessFiresOnce() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        await store.failNextPutShard(times: 1)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .updateFileEntry(for: path, base: nil, newEntry: makeManifestEntry(sha: "aaa"))

        guard case .wrote = outcome else { return XCTFail("expected .wrote, got \(outcome)") }
        XCTAssertEqual(counter.count, 1)
    }

    /// putShard の 412 がリトライ上限（5 回）まで続く → manifestUpdateFailed・発火 0 回。
    func test412ExhaustedDoesNotFire() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        await store.failNextPutShard(times: 5)

        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: "docs/a.txt", base: nil, newEntry: makeManifestEntry(sha: "aaa"))
            XCTFail("expected manifestUpdateFailed")
        } catch let SyncError.manifestUpdateFailed(message) {
            XCTAssertTrue(message.contains("conditional update failed"))
        }
        XCTAssertEqual(counter.count, 0)
    }

    /// 【PR #56 レビュー ①】putShard 成功 → updateIndex リトライ尽き:
    /// 「静かな成功」（外側リトライが manifestUpdateFailed を 412 と誤分類 → 再実行が
    /// .alreadyUpToDate 短絡で index 未更新のまま成功 return）に化けず、失敗として伝播する。
    func testIndexUpdateExhaustionThrowsInsteadOfSilentSuccess() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        await store.failNextPutIndex(times: 5)

        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: path, base: nil, newEntry: makeManifestEntry(sha: "aaa"))
            XCTFail("expected manifestUpdateFailed")
        } catch let SyncError.manifestUpdateFailed(message) {
            XCTAssertTrue(message.contains("index.json"))
        }
        XCTAssertEqual(counter.count, 0)
        // 分断状態の確認: シャードは書けたが index は未宣言
        let shardId = ManifestSharding.shardId(for: path)
        let shard = await store.shards[shardId]
        XCTAssertNotNil(shard?.files[path])
        let index = await store.index
        XCTAssertNil(index?.shards[shardId])
    }

    /// 【PR #56 レビュー ①】上の分断状態からの再試行（キューのバックオフ再試行に相当）は
    /// `.alreadyUpToDate` 再入で index を突合修復し、可視化の確定点として発火する。
    func testRetryAfterIndexFailureRepairsIndexAndFires() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let entry = makeManifestEntry(sha: "aaa")
        let shardId = ManifestSharding.shardId(for: path)
        await store.failNextPutIndex(times: 5)
        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: path, base: nil, newEntry: entry)
            XCTFail("expected manifestUpdateFailed")
        } catch SyncError.manifestUpdateFailed {}
        XCTAssertEqual(counter.count, 0)

        // 再試行: remote == uploading → .alreadyUpToDate だが index がずれている → 修復 + 発火
        let outcome = try await makeUpdater(store: store, counter: counter)
            .updateFileEntry(for: path, base: nil, newEntry: entry)

        XCTAssertEqual(outcome, .alreadyUpToDate(entry))
        XCTAssertEqual(counter.count, 1)
        let declared = await store.index?.shards[shardId]?.etag
        let actual = await store.shardEtags[shardId]
        XCTAssertNotNil(declared)
        XCTAssertEqual(declared, actual)
    }

    // MARK: - updateShard（削除経路）

    /// 削除で残エントリありのシャード書換 → 発火 1 回。
    func testUpdateShardRemovalFiresOnce() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        shard.files[path + ".keep"] = makeManifestEntry(sha: "bbb")
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
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
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

    /// 【PR #56 レビュー ②】マニフェスト不在パスへの no-op 削除は書かない・発火しない
    /// （consumed 済み delete の再試行 / 他デバイスが先に削除 / ENOENT からの delete 変換で到達）。
    func testNoopDeleteOnAbsentPathDoesNotWriteOrFire() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()

        try await makeUpdater(store: store, counter: counter).updateShard(for: "docs/none.txt") {
            $0.files.removeValue(forKey: "docs/none.txt")
        }

        XCTAssertEqual(counter.count, 0)
        let index = await store.index
        XCTAssertNil(index)
        let shards = await store.shards
        XCTAssertTrue(shards.isEmpty)
    }

    /// 【PR #56 レビュー ①②】deleteShard 成功 → updateIndex 失敗の再試行は、no-op でも
    /// index に残った宣言（dangling）を除去して発火する（削除側の突合修復）。
    func testNoopDeleteRepairsDanglingIndexDeclaration() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        await store.seed(shard: shard)
        await store.failNextPutIndex(times: 5)

        do {
            try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
                $0.files.removeValue(forKey: path)
            }
            XCTFail("expected manifestUpdateFailed")
        } catch SyncError.manifestUpdateFailed {}
        XCTAssertEqual(counter.count, 0)
        // 分断状態: シャードは削除済みだが index は宣言を残す
        let shardsAfterFail = await store.shards
        XCTAssertNil(shardsAfterFail[shardId])
        let danglingDeclared = await store.index?.shards[shardId]
        XCTAssertNotNil(danglingDeclared)

        // 再試行（同じ削除・今度は no-op）→ dangling 宣言を除去 + 発火
        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: path)
        }

        XCTAssertEqual(counter.count, 1)
        let declared = await store.index?.shards[shardId]
        XCTAssertNil(declared)
    }

    /// 【PR #56 再レビュー (4)】既存シャード + no-op 書換 + 宣言乖離 → 宣言のみ突合修復 + 発火
    /// （`updateShard` no-op の `if let etag` 側 = redeclare 分岐の直接テスト）。
    func testNoopUpdateShardRedeclaresStaleDeclarationAndFires() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        await store.seed(shard: shard)
        // index を触らずシャードだけ再 PUT → 宣言 stale を作る
        let cur = await store.shardEtags[shardId]
        _ = try await store.putShard(shard, ifMatch: cur)

        // 不在キーへの no-op delete → 内容は書かないが宣言のずれだけ修復 + 発火
        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: "docs/absent.txt")
        }

        XCTAssertEqual(counter.count, 1)
        let declared = await store.index?.shards[shardId]?.etag
        let actual = await store.shardEtags[shardId]
        XCTAssertEqual(declared, actual)
    }

    /// 【PR #56 再レビュー (3)】`.conflict` でも throw 前に宣言を突合修復する:
    /// updateIndex 未完の分断 → backoff 中のローカル再編集 → 幻影競合、の連鎖では
    /// `.alreadyUpToDate` に到達しないため、競合 throw 直前の修復が index stale を閉じる。
    func testConflictPathRepairsStaleIndexBeforeThrow() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "theirs")
        await store.seed(shard: shard)
        // 宣言 stale を作る（シャードだけ再 PUT）
        let cur = await store.shardEtags[shardId]
        _ = try await store.putShard(shard, ifMatch: cur)

        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: path, base: "base", newEntry: makeManifestEntry(sha: "mine"))
            XCTFail("expected uploadConflict")
        } catch SyncError.uploadConflict {}

        XCTAssertEqual(counter.count, 1)  // 修復分のみ（競合自体は非発火）
        let declared = await store.index?.shards[shardId]?.etag
        let actual = await store.shardEtags[shardId]
        XCTAssertEqual(declared, actual)
    }

    /// 【PR #56 再レビュー (1)】dangling 宣言の除去は CAS: 観測後に並行書き手 B が同シャードを
    /// 再宣言していたら中止し、B の正当な宣言を消さない（消すと「実在シャードが未宣言」=
    /// removedShards 誤検出 → 削除伝播に化ける最悪ケース）。
    func testDanglingRemovalCASAbortsOnConcurrentRedeclare() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        await store.seed(shard: shard)
        await store.failNextPutIndex(times: 5)
        do {
            try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
                $0.files.removeValue(forKey: path)
            }
            XCTFail("expected manifestUpdateFailed")
        } catch SyncError.manifestUpdateFailed {}
        // dangling 状態: シャード消滅・宣言残存。ここで B が観測直後に再宣言する状況を注入
        let bInfo = ManifestIndex.ShardInfo(etag: "etag-B", count: 7)
        await store.simulateConcurrentIndexWriteAfterNextGetIndex(shardId: shardId, info: bInfo)

        // 再試行（no-op）: 観測は stale 宣言 → コミット時には B の宣言 → CAS 中止・非発火
        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: path)
        }

        XCTAssertEqual(counter.count, 0)
        let declared = await store.index?.shards[shardId]?.etag
        XCTAssertEqual(declared, "etag-B")  // B の宣言が温存される
    }

    /// 【PR #56 再レビュー (1)】redeclare 修復（`.alreadyUpToDate` 再入）も CAS: 観測後に
    /// 並行書き手が宣言を動かしていたら stale 観測で巻き戻さない。
    func testRedeclareRepairCASAbortsOnConcurrentWriter() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let entry = makeManifestEntry(sha: "aaa")
        let shardId = ManifestSharding.shardId(for: path)
        await store.failNextPutIndex(times: 5)
        do {
            _ = try await makeUpdater(store: store, counter: counter)
                .updateFileEntry(for: path, base: nil, newEntry: entry)
            XCTFail("expected manifestUpdateFailed")
        } catch SyncError.manifestUpdateFailed {}
        // 分断状態（シャードあり・宣言なし）。観測直後に B が宣言を書く状況を注入
        let bInfo = ManifestIndex.ShardInfo(etag: "etag-B", count: 1)
        await store.simulateConcurrentIndexWriteAfterNextGetIndex(shardId: shardId, info: bInfo)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .updateFileEntry(for: path, base: nil, newEntry: entry)

        XCTAssertEqual(outcome, .alreadyUpToDate(entry))
        XCTAssertEqual(counter.count, 0)  // CAS 中止・非発火
        let declared = await store.index?.shards[shardId]?.etag
        XCTAssertEqual(declared, "etag-B")
    }

    /// 【PR #56 再々レビュー (a)】dangling 除去の「観測前の窓」: 外側 getShard(404) と宣言観測の
    /// 間隙に並行書き手の再作成（putShard + 宣言）が**両方**完了していた場合、その新鮮な宣言を
    /// stale と誤認せず、コミット前のシャード実在再確認で除去を中止する。
    func testDanglingRemovalAbortsWhenShardRecreatedBeforeObservation() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        await store.seed(shard: shard)
        await store.failNextPutIndex(times: 5)
        do {
            try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
                $0.files.removeValue(forKey: path)
            }
            XCTFail("expected manifestUpdateFailed")
        } catch SyncError.manifestUpdateFailed {}
        // dangling 状態。ここで「外側 getShard(404) の直後」に B の再作成（putShard + 宣言）が
        // 両方完了する状況を注入 → A は B の新鮮な宣言を dangling として観測してしまう
        var recreated = ManifestShard.empty(id: shardId)
        recreated.files["docs/other.txt"] = makeManifestEntry(sha: "bbb")
        await store.simulateConcurrentShardCreateAfterNextGetShard(recreated)

        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: path)
        }

        XCTAssertEqual(counter.count, 0)
        // B のシャードと宣言がそのまま生きている（実在シャードの未宣言化 = 削除伝播の遮断）
        let declared = await store.index?.shards[shardId]?.etag
        let actual = await store.shardEtags[shardId]
        XCTAssertNotNil(declared)
        XCTAssertEqual(declared, actual)
        let survivingShard = await store.shards[shardId]
        XCTAssertNotNil(survivingShard?.files["docs/other.txt"])
    }

    /// 【PR #56 再々レビュー (b)】空シャード削除の主経路の宣言除去も CAS: deleteShard 〜 index
    /// コミットの間に並行書き手が再作成（putShard + 宣言）していたら、その宣言を消さない・発火しない。
    /// B はシャードオブジェクト込みで注入する（実在の書き手 = 宣言の前に putShard 完了。
    /// 第 4 ラウンド (g) のフォールスルーは実在再確認で中止し、B を温存する）。
    /// （注入は updateIndex 内の fetch 直後に効くため、stale ifMatch の putIndex → 412 →
    /// リトライ再取得 → CAS 中止、という「リトライごとの CAS 再評価」経路も同時に踏む。）
    func testEmptyShardDeletionCASKeepsConcurrentRedeclaration() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        await store.seed(shard: shard)
        // updateIndex の fetch 直後に B が同シャードを再作成 + 再宣言する状況を注入
        var recreated = ManifestShard.empty(id: shardId)
        recreated.files["docs/other.txt"] = makeManifestEntry(sha: "bbb")
        let bInfo = ManifestIndex.ShardInfo(etag: "etag-B", count: 1)
        await store.simulateConcurrentIndexWriteAfterNextGetIndex(
            shardId: shardId, info: bInfo, shard: recreated
        )

        // 最後の 1 件を消す = 空シャード削除の主経路
        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: path)
        }

        XCTAssertEqual(counter.count, 0)  // 宣言は除去していない = 非発火
        let declared = await store.index?.shards[shardId]?.etag
        XCTAssertEqual(declared, "etag-B")  // B の宣言が温存される
        let survivingShard = await store.shards[shardId]
        XCTAssertNotNil(survivingShard?.files["docs/other.txt"])  // B のシャードも温存
    }

    /// 【PR #56 第 4 ラウンド (g)】主経路 CAS のガード失敗 + オブジェクト不在（= 先行分断の
    /// stale 宣言だった場合）は dangling 除去へフォールスルーし、宣言を除去 + 発火する。
    /// 放置すると主系は成功でキュー行を消すため再入が来ず、他デバイスが「宣言 == 記録済み etag」で
    /// スキャンをスキップし続けて削除が伝播しない（ghost 残存）。
    func testEmptyShardDeletionFallsThroughToRemoveStaleDanglingDeclaration() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        await store.seed(shard: shard)
        // 先行分断を模擬: シャードだけ再 PUT して宣言を stale（E_old）にする
        let cur = await store.shardEtags[shardId]
        _ = try await store.putShard(shard, ifMatch: cur)

        // 最後の 1 件の削除（主経路）: CAS は E_old ≠ 観測 etag で失敗するが、フォールスルーが
        // オブジェクト不在を確認して dangling 宣言を除去 + 発火する
        try await makeUpdater(store: store, counter: counter).updateShard(for: path) {
            $0.files.removeValue(forKey: path)
        }

        XCTAssertEqual(counter.count, 1)
        let declared = await store.index?.shards[shardId]
        XCTAssertNil(declared)
        let shards = await store.shards
        XCTAssertNil(shards[shardId])
    }

    // MARK: - removeFileEntry（FP 拡張の deleteItem 用・M5 Phase 5-2）

    /// ベース一致の削除 → 除去 + 発火。返り etag は実シャード etag（自世代 append 用）。
    func testRemoveFileEntryRemovesAndFires() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        shard.files[path + ".keep"] = makeManifestEntry(sha: "bbb")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntry(for: path, base: "aaa")

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(counter.count, 1)
        let stored = await store.shards[shardId]
        XCTAssertNil(stored?.files[path])
        XCTAssertNotNil(stored?.files[path + ".keep"])
        let declared = await store.index?.shards[shardId]
        XCTAssertEqual(declared?.count, 1)
    }

    /// 最後の 1 件の削除 → 空シャード削除 + 宣言除去 + 発火。
    func testRemoveFileEntryLastEntryDeletesShard() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntry(for: path, base: "aaa")

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(counter.count, 1)
        let stored = await store.shards[shardId]
        XCTAssertNil(stored)
        let declared = await store.index?.shards[shardId]
        XCTAssertNil(declared)
    }

    /// 不在 entry の削除 = 冪等成功（.alreadyGone）。書かない・発火しない。
    func testRemoveFileEntryAlreadyGoneDoesNotFire() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path + ".keep"] = makeManifestEntry(sha: "bbb")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntry(for: path, base: "aaa")

        guard case .alreadyGone = outcome else { return XCTFail("expected .alreadyGone, got \(outcome)") }
        XCTAssertEqual(counter.count, 0)
        let stored = await store.shards[shardId]
        XCTAssertNotNil(stored?.files[path + ".keep"])
    }

    /// 権威 entry がベースより進んでいる → 拒否（現 entry 添付）。除去しない・発火しない。
    func testRemoveFileEntryRejectsWhenRemoteChanged() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let remote = makeManifestEntry(sha: "theirs")
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = remote
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntry(for: path, base: "mine")

        XCTAssertEqual(outcome, .rejectedRemoteChanged(remote))
        XCTAssertEqual(counter.count, 0)
        let stored = await store.shards[shardId]
        XCTAssertEqual(stored?.files[path], remote)
    }

    /// ベース不明（nil）も拒否側へ倒す（根拠なしに消さない =「データ損失 < 重複」）。
    func testRemoveFileEntryRejectsNilBase() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let remote = makeManifestEntry(sha: "aaa")
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = remote
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntry(for: path, base: nil)

        XCTAssertEqual(outcome, .rejectedRemoteChanged(remote))
        XCTAssertEqual(counter.count, 0)
    }

    /// hook を明示 nil にしても全経路が従来どおり成功する（通知なしの明示宣言）。
    func testNilHookStillWrites() async throws {
        let store = InMemoryManifestStore()
        let updater = ManifestUpdater(store: store, deviceId: "test-device", onManifestDidWrite: nil)

        let outcome = try await updater.updateFileEntry(
            for: "docs/a.txt", base: nil, newEntry: makeManifestEntry(sha: "aaa")
        )
        guard case .wrote = outcome else { return XCTFail("expected .wrote, got \(outcome)") }
    }

    // MARK: - removeFileEntries（バッチ削除・M5 Phase 5-3）

    /// 同一シャードに載る 2 パスを実際の `ManifestSharding` で探す（sha 分布依存を排除）。
    private func findSameShardPair() -> (String, String) {
        var byShard: [String: String] = [:]
        for i in 0..<100_000 {
            let p = "batch/f\(i).txt"
            let s = ManifestSharding.shardId(for: p)
            if let existing = byShard[s] { return (existing, p) }
            byShard[s] = p
        }
        fatalError("no same-shard pair found")
    }

    /// 別シャードに載る 2 パスを「シャード id 昇順」で返す（処理順 = sorted の検証用）。
    private func findOrderedDifferentShardPair() -> (first: String, second: String) {
        let a = "batch/f0.txt"
        let sa = ManifestSharding.shardId(for: a)
        for i in 1..<100_000 {
            let p = "batch/f\(i).txt"
            let sp = ManifestSharding.shardId(for: p)
            if sp != sa {
                return sa < sp ? (a, p) : (p, a)
            }
        }
        fatalError("no different-shard pair found")
    }

    /// 全対象ベース一致 → 複数シャードをまたいで全除去。発火はシャード書込ごとに 1 回。
    func testBatchRemoveRemovesAcrossShards() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (p1, p2) = findOrderedDifferentShardPair()
        for path in [p1, p2] {
            var shard = ManifestShard.empty(id: ManifestSharding.shardId(for: path))
            shard.files[path] = makeManifestEntry(sha: "sha-\(path)")
            shard.files[path + ".keep"] = makeManifestEntry(sha: "keep")
            await store.seed(shard: shard)
        }

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntries(expecting: [p1: "sha-\(p1)", p2: "sha-\(p2)"])

        guard case .removed(let paths) = outcome else {
            return XCTFail("expected .removed, got \(outcome)")
        }
        XCTAssertEqual(Set(paths), [p1, p2])
        XCTAssertEqual(counter.count, 2)
        for path in [p1, p2] {
            let stored = await store.shards[ManifestSharding.shardId(for: path)]
            XCTAssertNil(stored?.files[path])
            XCTAssertNotNil(stored?.files[path + ".keep"])
        }
    }

    /// 同一シャード内の 1 件がベース不一致 → **そのシャードからは 1 件も除去しない**
    /// （部分シャードを作らない）・発火 0。
    func testBatchRemoveRejectionLeavesWholeShardUntouched() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (pa, pb) = findSameShardPair()
        let shardId = ManifestSharding.shardId(for: pa)
        let theirs = makeManifestEntry(sha: "theirs")
        var shard = ManifestShard.empty(id: shardId)
        shard.files[pa] = makeManifestEntry(sha: "sha-a")
        shard.files[pb] = theirs
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntries(expecting: [pa: "sha-a", pb: "mine"])

        guard case .rejected(let path, let remote, let removedPaths) = outcome else {
            return XCTFail("expected .rejected, got \(outcome)")
        }
        XCTAssertEqual(path, pb)
        XCTAssertEqual(remote, theirs)
        XCTAssertEqual(removedPaths, [])
        XCTAssertEqual(counter.count, 0)
        let stored = await store.shards[shardId]
        XCTAssertNotNil(stored?.files[pa])
        XCTAssertNotNil(stored?.files[pb])
    }

    /// 後段シャードで拒否 → 前段シャードの除去分は確定済みとして報告し、後段は無傷・以降中断。
    func testBatchRemoveRejectionReportsEarlierRemovals() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (first, second) = findOrderedDifferentShardPair()
        let theirs = makeManifestEntry(sha: "theirs")
        var shard1 = ManifestShard.empty(id: ManifestSharding.shardId(for: first))
        shard1.files[first] = makeManifestEntry(sha: "sha-first")
        await store.seed(shard: shard1)
        var shard2 = ManifestShard.empty(id: ManifestSharding.shardId(for: second))
        shard2.files[second] = theirs
        await store.seed(shard: shard2)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntries(expecting: [first: "sha-first", second: "mine"])

        guard case .rejected(let path, let remote, let removedPaths) = outcome else {
            return XCTFail("expected .rejected, got \(outcome)")
        }
        XCTAssertEqual(path, second)
        XCTAssertEqual(remote, theirs)
        XCTAssertEqual(removedPaths, [first])
        XCTAssertEqual(counter.count, 1)  // 前段シャードの書込のみ
        let stored1 = await store.shards[ManifestSharding.shardId(for: first)]
        XCTAssertNil(stored1)  // 唯一の entry を除去 → 空シャード削除
        let stored2 = await store.shards[ManifestSharding.shardId(for: second)]
        XCTAssertEqual(stored2?.files[second], theirs)
    }

    /// 不在パスは冪等スキップ。全対象不在なら書かない・発火しない・removed は空。
    func testBatchRemoveAbsentPathsAreIdempotent() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        var shard = ManifestShard.empty(id: ManifestSharding.shardId(for: path))
        shard.files[path + ".keep"] = makeManifestEntry(sha: "keep")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntries(expecting: [path: "gone", "docs/other.txt": "gone2"])

        guard case .removed(let paths) = outcome else {
            return XCTFail("expected .removed, got \(outcome)")
        }
        XCTAssertEqual(paths, [])
        XCTAssertEqual(counter.count, 0)
    }

    /// シャードの全 entry を除去 → 空シャード削除 + 宣言除去（`commitShardWrite` の共通テール）。
    func testBatchRemoveLastEntriesDeleteShard() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (pa, pb) = findSameShardPair()
        let shardId = ManifestSharding.shardId(for: pa)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[pa] = makeManifestEntry(sha: "sha-a")
        shard.files[pb] = makeManifestEntry(sha: "sha-b")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntries(expecting: [pa: "sha-a", pb: "sha-b"])

        guard case .removed(let paths) = outcome else {
            return XCTFail("expected .removed, got \(outcome)")
        }
        XCTAssertEqual(Set(paths), [pa, pb])
        XCTAssertEqual(counter.count, 1)
        let stored = await store.shards[shardId]
        XCTAssertNil(stored)
        let declared = await store.index?.shards[shardId]
        XCTAssertNil(declared)
    }

    // MARK: - moveFileEntries（rename/reparent・M5 Phase 5-4）

    private func makeMove(
        from: String, to: String, base: String, newSha: String? = nil
    ) -> ManifestFileMove {
        ManifestFileMove(
            fromPath: from, toPath: to, base: base,
            newEntry: makeManifestEntry(sha: newSha ?? base)
        )
    }

    /// クロスシャード move の基本形: add → remove の二相で新 entry が現れ旧 entry が消える。
    func testMoveAcrossShards() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (from, to) = findOrderedDifferentShardPair()
        var shard = ManifestShard.empty(id: ManifestSharding.shardId(for: from))
        shard.files[from] = makeManifestEntry(sha: "content")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .moveFileEntries([makeMove(from: from, to: to, base: "content")])

        guard case .moved(let removed) = outcome else {
            return XCTFail("expected .moved, got \(outcome)")
        }
        XCTAssertEqual(removed, [from])
        XCTAssertEqual(counter.count, 2)  // add 1 コミット + remove 1 コミット
        let fromShard = await store.shards[ManifestSharding.shardId(for: from)]
        XCTAssertNil(fromShard?.files[from])
        let toShard = await store.shards[ManifestSharding.shardId(for: to)]
        XCTAssertEqual(toShard?.files[to]?.sha256, "content")
    }

    /// 同一シャード内 move（from/to が同シャード）も二相で正しく収束する。
    func testMoveWithinSameShard() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (from, to) = findSameShardPair()
        let shardId = ManifestSharding.shardId(for: from)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[from] = makeManifestEntry(sha: "content")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .moveFileEntries([makeMove(from: from, to: to, base: "content")])

        guard case .moved(let removed) = outcome else {
            return XCTFail("expected .moved, got \(outcome)")
        }
        XCTAssertEqual(removed, [from])
        let stored = await store.shards[shardId]
        XCTAssertNil(stored?.files[from])
        XCTAssertEqual(stored?.files[to]?.sha256, "content")
    }

    /// 移動先に**別内容**の entry が実在 → destinationOccupied で中断・remove 未実施 = 元は無傷。
    func testMoveDestinationOccupiedAborts() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (from, to) = findSameShardPair()
        let shardId = ManifestSharding.shardId(for: from)
        let theirs = makeManifestEntry(sha: "theirs")
        var shard = ManifestShard.empty(id: shardId)
        shard.files[from] = makeManifestEntry(sha: "content")
        shard.files[to] = theirs
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .moveFileEntries([makeMove(from: from, to: to, base: "content")])

        XCTAssertEqual(outcome, .destinationOccupied(path: to, remote: theirs))
        XCTAssertEqual(counter.count, 0)
        let stored = await store.shards[shardId]
        XCTAssertEqual(stored?.files[from]?.sha256, "content")  // 元は無傷
        XCTAssertEqual(stored?.files[to], theirs)
    }

    /// 移動先に**同一 sha** の entry が実在（冪等再入 / 同一内容の先客）→ add は素通しで完走。
    func testMoveDestinationSameShaIsIdempotent() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (from, to) = findSameShardPair()
        let shardId = ManifestSharding.shardId(for: from)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[from] = makeManifestEntry(sha: "content")
        shard.files[to] = makeManifestEntry(sha: "content")
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .moveFileEntries([makeMove(from: from, to: to, base: "content")])

        guard case .moved(let removed) = outcome else {
            return XCTFail("expected .moved, got \(outcome)")
        }
        XCTAssertEqual(removed, [from])
        let stored = await store.shards[shardId]
        XCTAssertNil(stored?.files[from])
        XCTAssertEqual(stored?.files[to]?.sha256, "content")
    }

    /// remove フェーズで旧 entry がベースから進んでいた → sourceChanged・新旧両存のまま
    /// （自動 rollback しない）。
    func testMoveSourceChangedLeavesBothPaths() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (from, to) = findSameShardPair()
        let shardId = ManifestSharding.shardId(for: from)
        let theirs = makeManifestEntry(sha: "theirs")
        var shard = ManifestShard.empty(id: shardId)
        shard.files[from] = theirs  // ベース "mine" とは別内容に進んでいる
        await store.seed(shard: shard)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .moveFileEntries([makeMove(from: from, to: to, base: "mine", newSha: "mine")])

        guard case .sourceChanged(let path, let remote, let removedPaths) = outcome else {
            return XCTFail("expected .sourceChanged, got \(outcome)")
        }
        XCTAssertEqual(path, from)
        XCTAssertEqual(remote, theirs)
        XCTAssertEqual(removedPaths, [])
        let stored = await store.shards[shardId]
        XCTAssertEqual(stored?.files[from], theirs)  // 旧 = リモート版のまま温存
        XCTAssertEqual(stored?.files[to]?.sha256, "mine")  // 新 = 追加済み（両存）
    }

    /// 完了後の再入（同じ move の再実行）: add は同一 sha 素通し・remove は不在冪等 →
    /// removedPaths 空の .moved（marker の二重発行なし）。
    func testMoveIdempotentRerun() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (from, to) = findSameShardPair()
        var shard = ManifestShard.empty(id: ManifestSharding.shardId(for: from))
        shard.files[from] = makeManifestEntry(sha: "content")
        await store.seed(shard: shard)
        let updater = makeUpdater(store: store, counter: counter)
        let move = makeMove(from: from, to: to, base: "content")

        guard case .moved(let first) = try await updater.moveFileEntries([move]) else {
            return XCTFail("first run should move")
        }
        XCTAssertEqual(first, [from])

        guard case .moved(let second) = try await updater.moveFileEntries([move]) else {
            return XCTFail("rerun should be idempotent .moved")
        }
        XCTAssertEqual(second, [])
    }

    /// 複数 move（dir move 相当・複数シャード跨ぎ）が 1 回の呼び出しで全件収束する。
    func testMoveMultipleFilesAcrossShards() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (fromA, fromB) = findOrderedDifferentShardPair()
        let toA = fromA + ".moved"
        let toB = fromB + ".moved"
        for from in [fromA, fromB] {
            var shard = ManifestShard.empty(id: ManifestSharding.shardId(for: from))
            shard.files[from] = makeManifestEntry(sha: "sha-\(from)")
            await store.seed(shard: shard)
        }

        let outcome = try await makeUpdater(store: store, counter: counter).moveFileEntries([
            makeMove(from: fromA, to: toA, base: "sha-\(fromA)", newSha: "sha-\(fromA)"),
            makeMove(from: fromB, to: toB, base: "sha-\(fromB)", newSha: "sha-\(fromB)"),
        ])

        guard case .moved(let removed) = outcome else {
            return XCTFail("expected .moved, got \(outcome)")
        }
        XCTAssertEqual(Set(removed), [fromA, fromB])
        for (from, to) in [(fromA, toA), (fromB, toB)] {
            let fromShard = await store.shards[ManifestSharding.shardId(for: from)]
            XCTAssertNil(fromShard?.files[from])
            let toShard = await store.shards[ManifestSharding.shardId(for: to)]
            XCTAssertEqual(toShard?.files[to]?.sha256, "sha-\(from)")
        }
    }

    /// クロスシャードの複数 move で後続シャードが destinationOccupied → 先行シャードの add は
    /// 「移動先の重複」として残り（ドキュメント化された挙動）、remove は一切走らない = 元は無傷。
    func testMoveLaterShardOccupiedLeavesEarlierAddsAsDuplicates() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        // add フェーズはシャード id 昇順に処理される — to 側の順序で first/second を確定する
        let (toFirst, toSecond) = findOrderedDifferentShardPair()
        let fromA = toFirst + ".src"
        let fromB = toSecond + ".src"
        let theirs = makeManifestEntry(sha: "theirs")
        // 同一シャードに複数 seed が重なっても上書きしないよう、現状を読み足してから seed する
        for (path, entry) in [
            (fromA, makeManifestEntry(sha: "sha-a")),
            (fromB, makeManifestEntry(sha: "sha-b")),
            (toSecond, theirs),
        ] {
            let shardId = ManifestSharding.shardId(for: path)
            var shard = await store.shards[shardId] ?? ManifestShard.empty(id: shardId)
            shard.files[path] = entry
            await store.seed(shard: shard)
        }

        let outcome = try await makeUpdater(store: store, counter: counter).moveFileEntries([
            makeMove(from: fromA, to: toFirst, base: "sha-a", newSha: "sha-a"),
            makeMove(from: fromB, to: toSecond, base: "sha-b", newSha: "sha-b"),
        ])

        XCTAssertEqual(outcome, .destinationOccupied(path: toSecond, remote: theirs))
        // 先行シャードの add は確定済み（重複として残る = 冪等リトライ / pull で収束）
        let firstShard = await store.shards[ManifestSharding.shardId(for: toFirst)]
        XCTAssertEqual(firstShard?.files[toFirst]?.sha256, "sha-a")
        // remove フェーズ未実施 = 元 entry は両方無傷
        let srcA = await store.shards[ManifestSharding.shardId(for: fromA)]
        XCTAssertEqual(srcA?.files[fromA]?.sha256, "sha-a")
        let srcB = await store.shards[ManifestSharding.shardId(for: fromB)]
        XCTAssertEqual(srcB?.files[fromB]?.sha256, "sha-b")
        // 衝突先は無傷
        let dstB = await store.shards[ManifestSharding.shardId(for: toSecond)]
        XCTAssertEqual(dstB?.files[toSecond], theirs)
    }

    /// add フェーズの 412 リトライ（並行更新の一時失敗）→ 再取得・再評価して完走。
    func testMoveAddPhase412RetryThenSuccess() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let (from, to) = findSameShardPair()
        var shard = ManifestShard.empty(id: ManifestSharding.shardId(for: from))
        shard.files[from] = makeManifestEntry(sha: "content")
        await store.seed(shard: shard)
        await store.failNextPutShard(times: 1)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .moveFileEntries([makeMove(from: from, to: to, base: "content")])

        guard case .moved(let removed) = outcome else {
            return XCTFail("expected .moved, got \(outcome)")
        }
        XCTAssertEqual(removed, [from])
    }

    /// 412 リトライ（並行更新の一時失敗）→ 再取得・再評価して成功。発火は 1 回。
    func testBatchRemove412RetryThenSuccess() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "docs/a.txt"
        let shardId = ManifestSharding.shardId(for: path)
        var shard = ManifestShard.empty(id: shardId)
        shard.files[path] = makeManifestEntry(sha: "aaa")
        shard.files[path + ".keep"] = makeManifestEntry(sha: "keep")
        await store.seed(shard: shard)
        await store.failNextPutShard(times: 1)

        let outcome = try await makeUpdater(store: store, counter: counter)
            .removeFileEntries(expecting: [path: "aaa"])

        guard case .removed(let paths) = outcome else {
            return XCTFail("expected .removed, got \(outcome)")
        }
        XCTAssertEqual(paths, [path])
        XCTAssertEqual(counter.count, 1)
        let stored = await store.shards[shardId]
        XCTAssertNil(stored?.files[path])
    }
}
