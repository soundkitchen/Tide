import XCTest
import TideCore

/// `ManifestUpdater.writeFileEntries`（#140・パッケージの中身のまとめ書き）。
/// 「全部書き足してから消す」順・シャード単位の 3-way 判定・競合で除去に進まないこと・
/// 同じ内容の再試行で書かない / 発火しないこと・除去の拒否を固定する。
final class ManifestUpdaterBatchWriteTests: XCTestCase {
    private func makeUpdater(
        store: InMemoryManifestStore, counter: SignalCounter
    ) -> ManifestUpdater {
        ManifestUpdater(
            store: store,
            deviceId: "test-device",
            onManifestDidWrite: { counter.fire() },
            shardRetryPolicy: ManifestUpdaterTests.fastShardPolicy,
            indexRetryPolicy: ManifestUpdaterTests.fastIndexPolicy
        )
    }

    private func seed(_ store: InMemoryManifestStore, _ files: [String: ManifestFileEntry]) async {
        let groups = Dictionary(grouping: files.keys, by: ManifestSharding.shardId(for:))
        for (shardId, paths) in groups {
            var shard = ManifestShard.empty(id: shardId)
            for path in paths { shard.files[path] = files[path] }
            await store.seed(shard: shard)
        }
    }

    private func entry(at path: String, in store: InMemoryManifestStore) async -> ManifestFileEntry? {
        await store.shards[ManifestSharding.shardId(for: path)]?.files[path]
    }

    /// 異なるシャードに散る十分な数のパス（シャードは SHA-1 先頭 1 バイトなので 20 件あれば複数に散る）。
    private func memberPaths(_ prefix: String, count: Int = 20) -> [String] {
        (0..<count).map { "\(prefix)/m\($0).bin" }
    }

    func testUpsertsAndRemovalsAcrossShards() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let keep = memberPaths("Deck.key/keep")
        let gone = memberPaths("Deck.key/gone")
        var initial: [String: ManifestFileEntry] = [:]
        for path in keep + gone { initial[path] = makeManifestEntry(sha: "old") }
        await seed(store, initial)
        XCTAssertGreaterThan(Set((keep + gone).map(ManifestSharding.shardId(for:))).count, 1)

        let added = memberPaths("Deck.key/new")
        let upserts = keep.map { ManifestFileUpsert(path: $0, base: "old", newEntry: makeManifestEntry(sha: "new")) }
            + added.map { ManifestFileUpsert(path: $0, base: nil, newEntry: makeManifestEntry(sha: "add")) }
        let removals = Dictionary(uniqueKeysWithValues: gone.map { ($0, "old") })

        let outcome = try await makeUpdater(store: store, counter: counter)
            .writeFileEntries(upserting: upserts, removing: removals)

        guard case .written(let removedPaths) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Set(removedPaths), Set(gone))
        for path in keep { let e = await entry(at: path, in: store); XCTAssertEqual(e?.sha256, "new") }
        for path in added { let e = await entry(at: path, in: store); XCTAssertEqual(e?.sha256, "add") }
        for path in gone { let e = await entry(at: path, in: store); XCTAssertNil(e) }
        XCTAssertGreaterThan(counter.count, 0)
    }

    func testConflictStopsBeforeRemovalsAndLeavesThatShardUntouched() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let a = "Deck.key/a.bin"
        let b = "Deck.key/b.bin"
        let gone = "Deck.key/gone.bin"
        // b のリモートはベース（old）から進んでいる
        await seed(store, [
            a: makeManifestEntry(sha: "old"), b: makeManifestEntry(sha: "theirs"),
            gone: makeManifestEntry(sha: "old"),
        ])

        let outcome = try await makeUpdater(store: store, counter: counter).writeFileEntries(
            upserting: [
                ManifestFileUpsert(path: a, base: "old", newEntry: makeManifestEntry(sha: "mine")),
                ManifestFileUpsert(path: b, base: "old", newEntry: makeManifestEntry(sha: "mine")),
            ],
            removing: [gone: "old"])

        XCTAssertEqual(outcome, .conflict(path: b, remote: makeManifestEntry(sha: "theirs")))
        // 除去には進まない
        let goneEntry = await entry(at: gone, in: store)
        XCTAssertEqual(goneEntry?.sha256, "old")
        // b は上書きしない
        let bEntry = await entry(at: b, in: store)
        XCTAssertEqual(bEntry?.sha256, "theirs")
        // b と同じシャードの a も書かない（シャード単位で中断）
        if ManifestSharding.shardId(for: a) == ManifestSharding.shardId(for: b) {
            let aEntry = await entry(at: a, in: store)
            XCTAssertEqual(aEntry?.sha256, "old")
        }
    }

    func testRetryWithSameContentDoesNotWrite() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let paths = memberPaths("Deck.key/x")
        let upserts = paths.map { ManifestFileUpsert(path: $0, base: nil, newEntry: makeManifestEntry(sha: "s")) }
        let updater = makeUpdater(store: store, counter: counter)
        _ = try await updater.writeFileEntries(upserting: upserts, removing: [:])
        let fired = counter.count

        // 同じ内容・同じ版の再試行（前回の書込の再送）
        let outcome = try await updater.writeFileEntries(upserting: upserts, removing: [:])

        XCTAssertEqual(outcome, .written(removedPaths: []))
        XCTAssertEqual(counter.count, fired)
    }

    func testSameContentWithNewVersionRepoints() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let path = "Deck.key/a.bin"
        await seed(store, [path: makeManifestEntry(sha: "s")])  // 版 v-s
        var reuploaded = makeManifestEntry(sha: "s")
        reuploaded.s3VersionId = "v-new"

        _ = try await makeUpdater(store: store, counter: counter).writeFileEntries(
            upserting: [ManifestFileUpsert(path: path, base: "s", newEntry: reuploaded)], removing: [:])

        let stored = await entry(at: path, in: store)
        XCTAssertEqual(stored?.s3VersionId, "v-new")
        XCTAssertEqual(counter.count, 1)
    }

    func testRemovalRejectedAfterUpsertsComplete() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let a = "Deck.key/a.bin"
        let gone = "Deck.key/gone.bin"
        await seed(store, [gone: makeManifestEntry(sha: "theirs")])

        let outcome = try await makeUpdater(store: store, counter: counter).writeFileEntries(
            upserting: [ManifestFileUpsert(path: a, base: nil, newEntry: makeManifestEntry(sha: "mine"))],
            removing: [gone: "old"])

        XCTAssertEqual(
            outcome,
            .removalRejected(path: gone, remote: makeManifestEntry(sha: "theirs"), removedPaths: []))
        let aEntry = await entry(at: a, in: store)
        XCTAssertEqual(aEntry?.sha256, "mine")
        let goneEntry = await entry(at: gone, in: store)
        XCTAssertEqual(goneEntry?.sha256, "theirs")
    }

    func testRemovalsOnly() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let paths = memberPaths("Deck.key/r")
        var initial: [String: ManifestFileEntry] = [:]
        for path in paths { initial[path] = makeManifestEntry(sha: "old") }
        await seed(store, initial)

        let outcome = try await makeUpdater(store: store, counter: counter).writeFileEntries(
            upserting: [], removing: Dictionary(uniqueKeysWithValues: paths.map { ($0, "old") }))

        guard case .written(let removedPaths) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Set(removedPaths), Set(paths))
    }

    // MARK: - シャードの並行処理（同時に走る数を超える件数）

    func testManyShardsAreAllWrittenMovedAndRemoved() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let paths = memberPaths("Deck.key/many", count: 120)
        let shardCount = Set(paths.map(ManifestSharding.shardId(for:))).count
        XCTAssertGreaterThan(shardCount, 8 * 3)
        let updater = makeUpdater(store: store, counter: counter)

        let written = try await updater.writeFileEntries(
            upserting: paths.map { ManifestFileUpsert(path: $0, base: nil, newEntry: makeManifestEntry(sha: "s")) },
            removing: [:])
        XCTAssertEqual(written, .written(removedPaths: []))
        for path in paths { let e = await entry(at: path, in: store); XCTAssertEqual(e?.sha256, "s") }

        let moved = try await updater.moveFileEntries(paths.map {
            ManifestFileMove(
                fromPath: $0, toPath: "Moved/" + $0, base: "s", newEntry: makeManifestEntry(sha: "s"))
        })
        guard case .moved(let removedPaths) = moved else { return XCTFail("\(moved)") }
        XCTAssertEqual(Set(removedPaths), Set(paths))
        for path in paths {
            let old = await entry(at: path, in: store)
            XCTAssertNil(old)
            let new = await entry(at: "Moved/" + path, in: store)
            XCTAssertEqual(new?.sha256, "s")
        }
        // index の宣言はシャードの実体と一致する（並行の index 更新が取りこぼされていない）
        let index = await store.index
        let shards = await store.shards
        let etags = await store.shardEtags
        XCTAssertEqual(Set(index?.shards.keys ?? [:].keys), Set(shards.keys))
        for (shardId, info) in index?.shards ?? [:] {
            XCTAssertEqual(info.etag, etags[shardId], shardId)
            XCTAssertEqual(info.count, shards[shardId]?.files.count, shardId)
        }
    }

    /// 拒否で中断しても、消えたと報告した分は実際に消え、報告していない分は残る（marker の根拠）。
    func testRejectionAmongManyShardsReportsExactlyWhatWasRemoved() async throws {
        let store = InMemoryManifestStore()
        let counter = SignalCounter()
        let paths = memberPaths("Deck.key/rej", count: 120)
        // シャード id の順で真ん中あたりのパスだけ、リモートが先に進んでいる
        let theirsPath = paths.sorted { ManifestSharding.shardId(for: $0) < ManifestSharding.shardId(for: $1) }[60]
        var initial: [String: ManifestFileEntry] = [:]
        for path in paths { initial[path] = makeManifestEntry(sha: path == theirsPath ? "theirs" : "old") }
        await seed(store, initial)

        let outcome = try await makeUpdater(store: store, counter: counter).writeFileEntries(
            upserting: [], removing: Dictionary(uniqueKeysWithValues: paths.map { ($0, "old") }))

        guard case .removalRejected(let path, _, let removedPaths) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(path, theirsPath)
        XCTAssertLessThan(removedPaths.count, paths.count - 1)  // 新しいシャードへは進まない
        let removed = Set(removedPaths)
        for path in paths {
            let e = await entry(at: path, in: store)
            if removed.contains(path) {
                XCTAssertNil(e, path)
            } else {
                XCTAssertNotNil(e, path)
            }
        }
        // 拒否したシャードからは何も消さない
        let rejectedShard = ManifestSharding.shardId(for: theirsPath)
        XCTAssertFalse(removedPaths.contains { ManifestSharding.shardId(for: $0) == rejectedShard })
    }
}
