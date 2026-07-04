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
        XCTAssertTrue(changes.deletedPaths.isEmpty)
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
        XCTAssertTrue(changes.deletedPaths.isEmpty)
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
        XCTAssertEqual(changes.deletedPaths, ["docs", "docs/b.txt"])
    }

    func testKindChangeIsReportedAsUpdate() {
        // "a" がファイル → ディレクトリ（配下に a/b.txt）へ変わるケース: 同一 identifier の update
        let old = ManifestTree(files: ["a": entry()])
        let new = ManifestTree(files: ["a/b.txt": entry(sha: "bb")])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.updated.map(\.path), ["a", "a/b.txt"])
        XCTAssertEqual(changes.updated.first?.isDirectory, true)
        XCTAssertTrue(changes.deletedPaths.isEmpty)
    }

    func testEverythingDeletedWhenManifestEmpties() {
        let old = ManifestTree(files: ["a.txt": entry(), "docs/b.txt": entry()])
        let new = ManifestTree(files: [:])
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.updated.isEmpty)
        XCTAssertEqual(changes.deletedPaths, ["a.txt", "docs", "docs/b.txt"])
    }
}
