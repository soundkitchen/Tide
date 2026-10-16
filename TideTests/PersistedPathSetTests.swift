import XCTest
import TideCore

/// `PersistedPathSet`（M5 Phase 5-4・仮想フォルダ温存 + 除外後始末予約の汎用パス集合）の回帰固定。
/// - add / contains / subtree remove / subtree rename / 実体化による祖先掃除
/// - 永続化の往復・壊れ / bucket 不一致 / 不正パス混入の全体破棄（安全側 = 空集合）
/// - 上限超過 add の無視
/// - ドメイン epoch 不一致の全体破棄と capture 意味論（Issue #104）
final class PersistedPathSetTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vdr-test-\(UUID().uuidString).json")
    }

    func testAddContainsAndSubtreeRemove() async {
        let registry = PersistedPathSet(bucket: "b", fileURL: nil, epoch: nil)
        await registry.add("a")
        await registry.add("a/b")
        await registry.add("other")

        let hasA = await registry.contains("a")
        let hasAB = await registry.contains("a/b")
        XCTAssertTrue(hasA)
        XCTAssertTrue(hasAB)

        await registry.removeSubtree(at: "a")
        let hasA2 = await registry.contains("a")
        let hasAB2 = await registry.contains("a/b")
        let hasOther = await registry.contains("other")
        XCTAssertFalse(hasA2)
        XCTAssertFalse(hasAB2)
        XCTAssertTrue(hasOther)
    }

    func testRenameSubtree() async {
        let registry = PersistedPathSet(bucket: "b", fileURL: nil, epoch: nil)
        await registry.add("old")
        await registry.add("old/sub")
        await registry.add("unrelated")

        await registry.renameSubtree(from: "old", to: "new")

        let results = await (
            old: registry.contains("old"),
            oldSub: registry.contains("old/sub"),
            new: registry.contains("new"),
            newSub: registry.contains("new/sub"),
            unrelated: registry.contains("unrelated")
        )
        XCTAssertFalse(results.old)
        XCTAssertFalse(results.oldSub)
        XCTAssertTrue(results.new)
        XCTAssertTrue(results.newSub)
        XCTAssertTrue(results.unrelated)
    }

    /// ファイル実体化 → 祖先エントリだけが外れる（兄弟や無関係な仮想 dir は残る）。
    func testRemoveAncestorsOfMaterializedFile() async {
        let registry = PersistedPathSet(bucket: "b", fileURL: nil, epoch: nil)
        await registry.add("a")
        await registry.add("a/b")
        await registry.add("a/sibling")

        await registry.removeAncestors(of: "a/b/file.txt")

        let results = await (
            a: registry.contains("a"),
            ab: registry.contains("a/b"),
            sibling: registry.contains("a/sibling")
        )
        XCTAssertFalse(results.a)
        XCTAssertFalse(results.ab)
        XCTAssertTrue(results.sibling)
    }

    func testPersistenceRoundtrip() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        await registry.add("kept")
        await registry.add("dropped")
        await registry.removeSubtree(at: "dropped")

        let reloaded = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        let kept = await reloaded.contains("kept")
        let dropped = await reloaded.contains("dropped")
        XCTAssertTrue(kept)
        XCTAssertFalse(dropped)
    }

    /// bucket 不一致 / 壊れ JSON / 不正パス混入は全体破棄（空集合 = 温存保証だけ失う安全側）。
    func testLoadRejectsForeignOrCorruptPayload() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        await registry.add("mine")

        // bucket 不一致
        let other = PersistedPathSet(bucket: "other-bucket", fileURL: url, epoch: nil)
        let foreign = await other.contains("mine")
        XCTAssertFalse(foreign)

        // 不正パス混入（プロセス外改ざんの模倣）
        let tampered = """
            {"schemaVersion":2,"bucket":"b","paths":["ok","../escape"]}
            """
        try Data(tampered.utf8).write(to: url)
        let rejecting = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        let ok = await rejecting.contains("ok")
        XCTAssertFalse(ok)

        // 壊れ JSON
        try Data("not json".utf8).write(to: url)
        let corrupt = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        let any = await corrupt.contains("ok")
        XCTAssertFalse(any)
    }

    func testMaxEntriesCapIgnoresOverflow() async {
        let registry = PersistedPathSet(bucket: "b", fileURL: nil, epoch: nil)
        for i in 0..<PersistedPathSet.maxEntries {
            await registry.add("dir\(i)")
        }
        await registry.add("overflow")
        let hasOverflow = await registry.contains("overflow")
        let hasFirst = await registry.contains("dir0")
        XCTAssertFalse(hasOverflow)
        XCTAssertTrue(hasFirst)
    }

    // MARK: - 実体化バッジ向けの拡張（Issue #65）

    /// maxEntries は init 注入できる（既定 1000 のまま・バッジ用は引き上げ）。
    func testInjectedMaxEntriesIsHonored() async {
        let registry = PersistedPathSet(bucket: "b", fileURL: nil, epoch: nil, maxEntries: 2)
        await registry.add("a")
        await registry.add("b")
        await registry.add("c")
        let hasC = await registry.contains("c")
        let hasA = await registry.contains("a")
        XCTAssertFalse(hasC)
        XCTAssertTrue(hasA)
    }

    /// replace は集合を丸ごと差し替えて永続化し、上限超過はパス昇順 prefix で決定的に切り詰める
    /// （`MaterializedBadge.cappedReport` と同一規則 = 報告と永続の食い違いチャーン防止）。
    func testReplacePersistsAndCapsDeterministically() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedPathSetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("replace.json")

        let registry = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil, maxEntries: 2)
        await registry.replace(with: ["c", "a", "b"])
        // 昇順 prefix = a, b が生き残る
        let hasA = await registry.contains("a")
        let hasB = await registry.contains("b")
        let hasC = await registry.contains("c")
        XCTAssertTrue(hasA)
        XCTAssertTrue(hasB)
        XCTAssertFalse(hasC)

        // 永続往復（別インスタンスで読み直し）
        let reloaded = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil, maxEntries: 2)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot, ["a", "b"])

        // 空集合への差し替えも永続化される
        await registry.replace(with: [])
        let cleared = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil, maxEntries: 2)
        let emptied = await cleared.snapshot()
        XCTAssertEqual(emptied, [])
    }

    // MARK: - ドメイン epoch（Issue #104）

    /// epoch 一致（nil 同士 / 同値）は読める。不一致（別値・片側 nil）は全体破棄 —
    /// ドメイン作り直し後の stale レジストリがバッジ永久不点灯等で固着しない要。
    func testEpochMismatchDiscardsOnLoad() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PersistedPathSet(bucket: "b", fileURL: url, epoch: "gen-1")
        await registry.add("mine")

        let sameEpoch = await PersistedPathSet(bucket: "b", fileURL: url, epoch: "gen-1")
            .contains("mine")
        XCTAssertTrue(sameEpoch)

        let bumped = await PersistedPathSet(bucket: "b", fileURL: url, epoch: "gen-2")
            .contains("mine")
        XCTAssertFalse(bumped)

        let nilReader = await PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
            .contains("mine")
        XCTAssertFalse(nilReader)
    }

    /// nil epoch（クリーンインストール = 一度もドメイン除去していない環境）で書いた payload は、
    /// bump 後（非 nil epoch）の読み手には見えない。
    func testNilEpochPayloadInvisibleAfterBump() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        await registry.add("mine")

        let nilRoundtrip = await PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
            .contains("mine")
        XCTAssertTrue(nilRoundtrip)

        let afterBump = await PersistedPathSet(bucket: "b", fileURL: url, epoch: "gen-1")
            .contains("mine")
        XCTAssertFalse(afterBump)
    }

    /// capture 意味論: 旧 epoch で構築済みのインスタンス（= 生き残りの旧拡張プロセス）が
    /// アプリの bump **後**に persist しても、payload は構築時 capture の旧 epoch でスタンプ
    /// されるため、新 epoch の読み手には現れない（別プロセス間の削除レースの構造的解消）。
    func testStaleProcessLatePersistIsInvalidatedByCapturedEpoch() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let staleProcess = PersistedPathSet(bucket: "b", fileURL: url, epoch: "gen-1")
        await staleProcess.add("early")

        // ここでアプリが epoch を "gen-2" へ bump した想定。旧プロセスはさらに書き続ける。
        await staleProcess.add("late")

        let newReader = PersistedPathSet(bucket: "b", fileURL: url, epoch: "gen-2")
        let snapshot = await newReader.snapshot()
        XCTAssertEqual(snapshot, [])
    }

    /// v1 payload（epoch フィールド以前）は schemaVersion 不一致で一度だけ全体破棄される =
    /// 既存環境の stale レジストリ（#104 の固着）がアプリ更新だけで自己治癒する回帰固定。
    func testSchemaV1PayloadIsDiscarded() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let v1 = """
            {"schemaVersion":1,"bucket":"b","paths":["stale"]}
            """
        try Data(v1.utf8).write(to: url)
        let reader = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        let hasStale = await reader.contains("stale")
        XCTAssertFalse(hasStale)
    }

    // MARK: - 保存の成否を確かめる add（#120 F1）

    /// 書き込めない場所（存在しないディレクトリの下）を指す URL。
    private func unwritableURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vdr-missing-\(UUID().uuidString)")
            .appendingPathComponent("holds.json")
    }

    func testAddDurablySucceedsAndPersists() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        let ok = await registry.addDurably("a/node_modules")
        XCTAssertTrue(ok)
        // 既に入っていて保存も成功している path は true のまま
        let again = await registry.addDurably("a/node_modules")
        XCTAssertTrue(again)
        let reloaded = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil)
        let persisted = await reloaded.contains("a/node_modules")
        XCTAssertTrue(persisted)
    }

    func testAddDurablyWithoutFileURLIsRejected() async {
        // 保存先の無い縮退時は再起動を跨ぐ保証が無いので加えない
        let registry = PersistedPathSet(bucket: "b", fileURL: nil, epoch: nil)
        let ok = await registry.addDurably("a")
        let has = await registry.contains("a")
        XCTAssertFalse(ok)
        XCTAssertFalse(has)
    }

    func testAddDurablyRollsBackOnSaveFailure() async {
        // 保存に失敗したら、加えた分をメモリからも取り消す（受理したフォルダに予約を残さない）
        let registry = PersistedPathSet(bucket: "b", fileURL: unwritableURL(), epoch: nil)
        let ok = await registry.addDurably("a")
        let has = await registry.contains("a")
        XCTAssertFalse(ok)
        XCTAssertFalse(has)
    }

    func testAddDurablyKeepsExistingEntryAfterSaveFailure() async {
        // 先に入っていた path は、保存に失敗していても取り消さない（先行する予約を消さない）
        let registry = PersistedPathSet(bucket: "b", fileURL: unwritableURL(), epoch: nil)
        await registry.add("a")
        let ok = await registry.addDurably("a")
        let has = await registry.contains("a")
        XCTAssertFalse(ok)
        XCTAssertTrue(has)
    }

    func testAddDurablyOverCapIsRejected() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PersistedPathSet(bucket: "b", fileURL: url, epoch: nil, maxEntries: 1)
        let first = await registry.addDurably("a")
        let second = await registry.addDurably("b")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }
}
