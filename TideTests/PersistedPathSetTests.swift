import XCTest
import TideCore

/// `PersistedPathSet`（M5 Phase 5-4・仮想フォルダ温存 + 除外後始末予約の汎用パス集合）の回帰固定。
/// - add / contains / subtree remove / subtree rename / 実体化による祖先掃除
/// - 永続化の往復・壊れ / bucket 不一致 / 不正パス混入の全体破棄（安全側 = 空集合）
/// - 上限超過 add の無視
final class PersistedPathSetTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vdr-test-\(UUID().uuidString).json")
    }

    func testAddContainsAndSubtreeRemove() async {
        let registry = PersistedPathSet(bucket: "b", fileURL: nil)
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
        let registry = PersistedPathSet(bucket: "b", fileURL: nil)
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
        let registry = PersistedPathSet(bucket: "b", fileURL: nil)
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
        let registry = PersistedPathSet(bucket: "b", fileURL: url)
        await registry.add("kept")
        await registry.add("dropped")
        await registry.removeSubtree(at: "dropped")

        let reloaded = PersistedPathSet(bucket: "b", fileURL: url)
        let kept = await reloaded.contains("kept")
        let dropped = await reloaded.contains("dropped")
        XCTAssertTrue(kept)
        XCTAssertFalse(dropped)
    }

    /// bucket 不一致 / 壊れ JSON / 不正パス混入は全体破棄（空集合 = 温存保証だけ失う安全側）。
    func testLoadRejectsForeignOrCorruptPayload() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PersistedPathSet(bucket: "b", fileURL: url)
        await registry.add("mine")

        // bucket 不一致
        let other = PersistedPathSet(bucket: "other-bucket", fileURL: url)
        let foreign = await other.contains("mine")
        XCTAssertFalse(foreign)

        // 不正パス混入（プロセス外改ざんの模倣）
        let tampered = """
            {"schemaVersion":1,"bucket":"b","paths":["ok","../escape"]}
            """
        try Data(tampered.utf8).write(to: url)
        let rejecting = PersistedPathSet(bucket: "b", fileURL: url)
        let ok = await rejecting.contains("ok")
        XCTAssertFalse(ok)

        // 壊れ JSON
        try Data("not json".utf8).write(to: url)
        let corrupt = PersistedPathSet(bucket: "b", fileURL: url)
        let any = await corrupt.contains("ok")
        XCTAssertFalse(any)
    }

    func testMaxEntriesCapIgnoresOverflow() async {
        let registry = PersistedPathSet(bucket: "b", fileURL: nil)
        for i in 0..<PersistedPathSet.maxEntries {
            await registry.add("dir\(i)")
        }
        await registry.add("overflow")
        let hasOverflow = await registry.contains("overflow")
        let hasFirst = await registry.contains("dir0")
        XCTAssertFalse(hasOverflow)
        XCTAssertTrue(hasFirst)
    }
}
