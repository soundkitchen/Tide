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
        XCTAssertEqual(tree.node(at: ""), .directory(path: ""))
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

    func testNodeNameAndRoot() {
        let tree = ManifestTree(files: ["docs/report.pdf": entry()])
        XCTAssertEqual(tree.node(at: "docs/report.pdf")?.name, "report.pdf")
        XCTAssertEqual(tree.node(at: "docs")?.name, "docs")
        XCTAssertEqual(tree.node(at: "")?.name, "")
    }
}
