import XCTest
@testable import Tide

final class SyncIgnoreMatcherTests: XCTestCase {
    private func m(_ text: String) -> SyncIgnoreMatcher { SyncIgnoreMatcher.parse(text) }

    func testEmptyMatcherIgnoresNothing() {
        XCTAssertFalse(SyncIgnoreMatcher.empty.isIgnored("foo.txt"))
        XCTAssertFalse(m("").isIgnored("foo.txt"))
    }

    func testStarExtension() {
        let s = m("*.log")
        XCTAssertTrue(s.isIgnored("foo.log"))
        XCTAssertTrue(s.isIgnored("a/b/foo.log"))   // スラッシュ無し → 任意階層
        XCTAssertFalse(s.isIgnored("foo.txt"))
        XCTAssertFalse(s.isIgnored("foo.log.txt"))  // 末尾一致のみ
    }

    func testDirectoryPattern() {
        let s = m("build/")
        XCTAssertTrue(s.isIgnored("build/output.o"))
        XCTAssertTrue(s.isIgnored("a/build/output.o"))
        XCTAssertFalse(s.isIgnored("build"))        // build という名前のファイルは対象外
        XCTAssertFalse(s.isIgnored("rebuild/x"))    // 前方一致ではない
    }

    func testRootAnchored() {
        let s = m("/root-only.txt")
        XCTAssertTrue(s.isIgnored("root-only.txt"))
        XCTAssertFalse(s.isIgnored("sub/root-only.txt"))
    }

    func testInternalSlashIsAnchored() {
        let s = m("doc/frotz")
        XCTAssertTrue(s.isIgnored("doc/frotz"))
        XCTAssertTrue(s.isIgnored("doc/frotz/file"))  // 祖先ディレクトリとしてマッチ
        XCTAssertFalse(s.isIgnored("a/doc/frotz"))
    }

    func testDoubleStarLeading() {
        let s = m("**/node_modules")
        XCTAssertTrue(s.isIgnored("node_modules/x"))
        XCTAssertTrue(s.isIgnored("a/b/node_modules/x"))
        XCTAssertFalse(s.isIgnored("a/node_modules_x/y"))
    }

    func testDoubleStarMiddle() {
        let s = m("a/**/b")
        XCTAssertTrue(s.isIgnored("a/b"))
        XCTAssertTrue(s.isIgnored("a/x/b"))
        XCTAssertTrue(s.isIgnored("a/x/y/b"))
        XCTAssertFalse(s.isIgnored("a/b2"))
    }

    func testTrailingDoubleStar() {
        let s = m("logs/**")
        XCTAssertTrue(s.isIgnored("logs/a"))
        XCTAssertTrue(s.isIgnored("logs/a/b.txt"))
        XCTAssertFalse(s.isIgnored("logs"))
    }

    func testQuestionMark() {
        let s = m("file?.txt")
        XCTAssertTrue(s.isIgnored("file1.txt"))
        XCTAssertFalse(s.isIgnored("file.txt"))
        XCTAssertFalse(s.isIgnored("file12.txt"))
    }

    func testNegationReinclude() {
        let s = m("*.log\n!important.log")
        XCTAssertTrue(s.isIgnored("foo.log"))
        XCTAssertFalse(s.isIgnored("important.log"))
        XCTAssertFalse(s.isIgnored("a/important.log"))  // 任意階層で再包含
    }

    func testCommentsAndBlankLines() {
        let s = m("# comment\n\n*.tmp\n   \n")
        XCTAssertTrue(s.isIgnored("x.tmp"))
        XCTAssertFalse(s.isIgnored("x.txt"))
        XCTAssertEqual(s.sourceLines, ["*.tmp"])
    }

    func testEscapedHash() {
        let s = m("\\#literal")
        XCTAssertTrue(s.isIgnored("#literal"))
    }

    func testCaseSensitive() {
        // gitignore 既定の case-sensitive 挙動
        let s = m("*.log")
        XCTAssertFalse(s.isIgnored("FOO.LOG"))
    }

    func testDotfilePattern() {
        let s = m(".cache")
        XCTAssertTrue(s.isIgnored(".cache"))
        XCTAssertTrue(s.isIgnored("sub/.cache"))
        XCTAssertTrue(s.isIgnored(".cache/data"))
    }

    func testDefaultTemplateExcludesCommonJunk() {
        let s = SyncIgnoreMatcher.parse(SyncIgnoreMatcher.defaultTemplate)
        XCTAssertTrue(s.isIgnored("node_modules/left-pad/index.js"))
        XCTAssertTrue(s.isIgnored("sub/node_modules/x"))
        XCTAssertTrue(s.isIgnored("__pycache__/foo.cpython-311.pyc"))
        XCTAssertTrue(s.isIgnored("app/foo.pyc"))
        XCTAssertTrue(s.isIgnored(".build/debug/x"))
        XCTAssertTrue(s.isIgnored("DerivedData/Tide/x"))
        // 通常ファイルは除外されない
        XCTAssertFalse(s.isIgnored("src/main.swift"))
        XCTAssertFalse(s.isIgnored("README.md"))
        // .git は既定テンプレートでは除外しない（復旧目的で同期対象のまま）
        XCTAssertFalse(s.isIgnored(".git/HEAD"))
    }

    func testPatternCountCapDoesNotCrash() {
        let many = (0..<(SyncIgnoreMatcher.maxPatterns + 10))
            .map { "p\($0)" }
            .joined(separator: "\n")
        let s = m(many)
        XCTAssertTrue(s.isIgnored("p0"))            // 先頭は採用される
        XCTAssertEqual(s.sourceLines.count, SyncIgnoreMatcher.maxPatterns)
    }
}
