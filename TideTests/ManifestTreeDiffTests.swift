import XCTest
import TideCore
@testable import Tide

/// 世代間ツリー diff（M5 Phase 4・増分列挙）。updated / deleted の写像と
/// ディレクトリ（出現・mtime 前進・消滅）の扱いを固定する。
final class ManifestTreeDiffTests: XCTestCase {
    private func entry(mtime: String = "2026-07-01T00:00:00Z", sha: String = "aa") -> ManifestFileEntry {
        ManifestFileEntry(
            size: 1, mtime: mtime, sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: mtime
        )
    }

    func testNoChangesIsEmpty() {
        let files = ["a.txt": entry(), "docs/b.txt": entry()]
        let changes = ManifestTreeDiff.changes(
            from: ManifestTree(files: files), to: ManifestTree(files: files)
        )
        XCTAssertTrue(changes.isEmpty)
    }

    func testAddedFileReportsFileAndNewDirectories() {
        let old = ManifestTree(files: ["a.txt": entry()])
        let new = ManifestTree(files: [
            "a.txt": entry(),
            "docs/sub/new.txt": entry(mtime: "2026-07-02T00:00:00Z", sha: "bb"),
        ])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        // 新規ファイル + 出現した中間ディレクトリ（docs, docs/sub）が path 昇順で並ぶ
        XCTAssertEqual(changes.updated.map(\.path), ["docs", "docs/sub", "docs/sub/new.txt"])
        XCTAssertTrue(changes.deleted.isEmpty)
        // ルートは対象外
        XCTAssertFalse(changes.updated.contains { $0.path.isEmpty })
    }

    func testChangedEntryReportsFileAndAncestorMtimeForwarding() {
        let old = ManifestTree(files: [
            "docs/a.txt": entry(mtime: "2026-07-01T00:00:00Z", sha: "aa"),
        ])
        let new = ManifestTree(files: [
            "docs/a.txt": entry(mtime: "2026-07-03T00:00:00Z", sha: "bb"),
        ])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        // ファイル本体 + 合成 mtime が前進した祖先ディレクトリの両方が updated
        XCTAssertEqual(changes.updated.map(\.path), ["docs", "docs/a.txt"])
        XCTAssertTrue(changes.deleted.isEmpty)
    }

    func testDeletedFileReportsFileAndEmptiedDirectory() {
        let old = ManifestTree(files: [
            "a.txt": entry(),
            "docs/b.txt": entry(),
        ])
        let new = ManifestTree(files: ["a.txt": entry()])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.updated.isEmpty)
        // ファイルと、空になって消えた合成ディレクトリの両方が deleted
        XCTAssertEqual(changes.deleted.map(\.path), ["docs", "docs/b.txt"])
    }

    func testKindChangeFileToDirectorySplitsIntoDeleteAndUpdate() {
        // "a" がファイル → ディレクトリ（配下に a/b.txt）: 同一 identifier の update 単発では
        // fileproviderd が受理しない（itemKindMismatch・2026-07-05 実機確定）ため、
        // delete（旧 kind）+ update（新 kind）に分解する（M5 Phase 5-1）
        let old = ManifestTree(files: ["a": entry()])
        let new = ManifestTree(files: ["a/b.txt": entry(sha: "bb")])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.updated.map(\.path), ["a", "a/b.txt"])
        XCTAssertEqual(changes.updated.first?.isDirectory, true)
        XCTAssertEqual(changes.deleted.map(\.path), ["a"])
        // 旧 kind（ファイル）のノードとして返る = 呼び出し側が旧 id（f:a）を組める
        XCTAssertEqual(changes.deleted.first?.isDirectory, false)
    }

    func testKindChangeDirectoryToFileSplitsIntoDeleteAndUpdate() {
        // "a"（dir・配下 a/b.txt）→ "a"（ファイル）: 子の消滅の delete と kind 変化の delete が
        // どちらも deleted に入る（path 昇順・kind 情報付き）
        let old = ManifestTree(files: ["a/b.txt": entry()])
        let new = ManifestTree(files: ["a": entry(sha: "cc")])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.updated.map(\.path), ["a"])
        XCTAssertEqual(changes.updated.first?.isDirectory, false)
        XCTAssertEqual(changes.deleted.map(\.path), ["a", "a/b.txt"])
        // 旧 kind（ディレクトリ）のノードとして返る = 旧 id（d:a）を組める
        XCTAssertEqual(changes.deleted.first?.isDirectory, true)
    }

    func testNestedKindChangeSplitsOnlyTheChangedPath() {
        // ネスト位置の kind 変化（x/y ファイル → dir）でも分解対象は当該 path のみ。
        // 祖先 x は合成 mtime 不変なら updated に入らない（余計な delete も出ない）
        let mt = "2026-07-01T00:00:00Z"
        let old = ManifestTree(files: ["x/y": entry(mtime: mt)])
        let new = ManifestTree(files: ["x/y/z.txt": entry(mtime: mt, sha: "bb")])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.updated.map(\.path), ["x/y", "x/y/z.txt"])
        XCTAssertEqual(changes.deleted.map(\.path), ["x/y"])
        XCTAssertEqual(changes.deleted.first?.isDirectory, false)
    }

    func testEverythingDeletedWhenManifestEmpties() {
        let old = ManifestTree(files: ["a.txt": entry(), "docs/b.txt": entry()])
        let new = ManifestTree(files: [:])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.updated.isEmpty)
        XCTAssertEqual(changes.deleted.map(\.path), ["a.txt", "docs", "docs/b.txt"])
    }
}
