import XCTest
import TideCore
@testable import Tide

final class ManifestTreeTests: XCTestCase {
    private func entry(size: Int64 = 1, sha: String = "aa") -> ManifestFileEntry {
        ManifestFileEntry(
            size: size, mtime: "2026-07-03T00:00:00Z", sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: "2026-07-03T00:00:00Z"
        )
    }

    func testRootChildrenSortedByName() {
        let tree = ManifestTree(files: [
            "b.txt": entry(),
            "a.txt": entry(),
            "docs/report.pdf": entry(),
        ])
        let children = tree.children(of: "")
        XCTAssertEqual(children?.map(\.name), ["a.txt", "b.txt", "docs"])
        XCTAssertEqual(children?.map(\.isDirectory), [false, false, true])
    }

    func testSynthesizesIntermediateDirectories() {
        let tree = ManifestTree(files: ["a/b/c/deep.txt": entry()])
        XCTAssertEqual(tree.children(of: "")?.map(\.path), ["a"])
        XCTAssertEqual(tree.children(of: "a")?.map(\.path), ["a/b"])
        XCTAssertEqual(tree.children(of: "a/b")?.map(\.path), ["a/b/c"])
        XCTAssertEqual(tree.children(of: "a/b/c")?.map(\.path), ["a/b/c/deep.txt"])
        XCTAssertEqual(tree.node(at: "a/b")?.isDirectory, true)
        XCTAssertEqual(tree.node(at: "a/b/c/deep.txt")?.isDirectory, false)
    }

    func testMissingDirectoryReturnsNil() {
        let tree = ManifestTree(files: ["a.txt": entry()])
        XCTAssertNil(tree.children(of: "nope"))
        XCTAssertNil(tree.node(at: "nope/x.txt"))
    }

    func testEmptyManifestHasEmptyRoot() {
        let tree = ManifestTree(files: [:])
        XCTAssertEqual(tree.children(of: ""), [])
        XCTAssertEqual(tree.node(at: ""), .directory(path: "", mtime: nil))
    }

    func testDirectoryWinsOverConflictingFilePath() {
        // "a" がファイルとしても "a/b.txt" の中間ディレクトリとしても現れる壊れたマニフェスト:
        // ディレクトリを優先し、ファイル "a" は捨てる（列挙の整合性を守る）
        let tree = ManifestTree(files: [
            "a/b.txt": entry(),
            "a": entry(),
        ])
        XCTAssertEqual(tree.node(at: "a")?.isDirectory, true)
        XCTAssertEqual(tree.children(of: "a")?.map(\.path), ["a/b.txt"])
        // 逆順の挿入に依存しないこと（辞書順序は不定）は directory-wins ルールで担保される
    }

    func testDirectoryWinsIsInsertionOrderIndependent() {
        // Dictionary の走査順（per-process シード）に依存せず directory-wins が成立すること。
        // 旧実装は「ファイルが先に走査された」場合に中間ディレクトリ合成が置換せず、
        // 非フォルダを親に持つ到達不能ノードができた（PR #50 レビュー #1）。
        // 衝突ペアを複数・深さ違いで与え、どの走査順でも全ペアがディレクトリ化することを確認する。
        var files: [String: ManifestFileEntry] = [:]
        for i in 0..<8 {
            files["c\(i)"] = entry()
            files["c\(i)/leaf.txt"] = entry()
        }
        files["x/y"] = entry()
        files["x/y/z.txt"] = entry()

        let tree = ManifestTree(files: files)

        for i in 0..<8 {
            XCTAssertEqual(tree.node(at: "c\(i)")?.isDirectory, true, "c\(i) should be a directory")
            XCTAssertEqual(tree.children(of: "c\(i)")?.map(\.path), ["c\(i)/leaf.txt"])
        }
        XCTAssertEqual(tree.node(at: "x/y")?.isDirectory, true)
        XCTAssertEqual(tree.children(of: "x/y")?.map(\.path), ["x/y/z.txt"])
    }

    func testNodeNameAndRoot() {
        let tree = ManifestTree(files: ["docs/report.pdf": entry()])
        XCTAssertEqual(tree.node(at: "docs/report.pdf")?.name, "report.pdf")
        XCTAssertEqual(tree.node(at: "docs")?.name, "docs")
        XCTAssertEqual(tree.node(at: "")?.name, "")
    }

    // MARK: - ディレクトリの合成 mtime（M5 Phase 4）

    private func entry(mtime: String, sha: String = "aa") -> ManifestFileEntry {
        ManifestFileEntry(
            size: 1, mtime: mtime, sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: mtime
        )
    }

    func testDirectoryMtimeIsMaxOfDescendants() {
        let tree = ManifestTree(files: [
            "docs/old.txt": entry(mtime: "2026-01-01T00:00:00Z"),
            "docs/sub/new.txt": entry(mtime: "2026-06-15T12:00:00Z"),
            "docs/mid.txt": entry(mtime: "2026-03-01T00:00:00Z"),
        ])
        let newest = ISO8601.parse("2026-06-15T12:00:00Z")
        XCTAssertEqual(tree.node(at: "docs"), .directory(path: "docs", mtime: newest))
        XCTAssertEqual(tree.node(at: "docs/sub"), .directory(path: "docs/sub", mtime: newest))
        // children(of:) 経由でも同じ mtime 付きノードが返る（注入漏れ防止）
        XCTAssertEqual(
            tree.children(of: "")?.first { $0.path == "docs" },
            .directory(path: "docs", mtime: newest)
        )
    }

    func testRootMtimeStaysNil() {
        // root は item(for:) の高速パス（マニフェスト非依存）と itemVersion を揃えるため常に nil
        let tree = ManifestTree(files: ["a.txt": entry(mtime: "2026-06-15T12:00:00Z")])
        XCTAssertEqual(tree.node(at: ""), .directory(path: "", mtime: nil))
    }

    func testUnparsableMtimeLeavesDirectoryMtimeNil() {
        let tree = ManifestTree(files: ["docs/bad.txt": entry(mtime: "not-a-date")])
        XCTAssertEqual(tree.node(at: "docs"), .directory(path: "docs", mtime: nil))
    }

    func testDirectoryMtimeIsDeterministicWhenFileReplacedByDirectory() {
        // PR #51 レビュー #2: "a/b"（ファイル）と "a/b/c.txt" が両方ある壊れたマニフェスト
        //（file→dir 置換バグ = Issue #52 が作る状態）では、directory-wins で捨てられた
        // ファイル "a/b" の mtime を**畳み込まない**こと。挿入時畳み込みだと Dictionary の
        // 走査順（プロセスごとに不定）で結果が変わり、世代間 diff が幻のディレクトリ更新を出す。
        let newer = "2026-07-04T00:00:00Z"
        let older = "2026-01-01T00:00:00Z"
        let tree = ManifestTree(files: [
            "a/b": entry(mtime: newer),          // directory-wins で捨てられる（newer は無効）
            "a/b/c.txt": entry(mtime: older),    // 生き残る唯一のファイル
        ])
        let expected = ISO8601.parse(older)
        XCTAssertEqual(tree.node(at: "a"), .directory(path: "a", mtime: expected))
        XCTAssertEqual(tree.node(at: "a/b"), .directory(path: "a/b", mtime: expected))
    }
}
