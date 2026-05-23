import XCTest
@testable import Tide

final class PathValidatorTests: XCTestCase {

    // MARK: - validateRelativePath

    func testAcceptsNormalPaths() throws {
        try PathValidator.validateRelativePath("foo.txt")
        try PathValidator.validateRelativePath("Documents/report.pdf")
        try PathValidator.validateRelativePath(".git/HEAD")     // hidden ファイルは許容
        try PathValidator.validateRelativePath("a/b/c/d/e.bin")
        try PathValidator.validateRelativePath("日本語ファイル.txt")
    }

    func testRejectsEmptyPath() {
        XCTAssertThrowsError(try PathValidator.validateRelativePath(""))
    }

    func testRejectsAbsolutePath() {
        XCTAssertThrowsError(try PathValidator.validateRelativePath("/etc/passwd"))
    }

    func testRejectsDotComponents() {
        XCTAssertThrowsError(try PathValidator.validateRelativePath(".."))
        XCTAssertThrowsError(try PathValidator.validateRelativePath("../foo"))
        XCTAssertThrowsError(try PathValidator.validateRelativePath("foo/.."))
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a/../b"))
        XCTAssertThrowsError(try PathValidator.validateRelativePath("."))
        XCTAssertThrowsError(try PathValidator.validateRelativePath("./foo"))
    }

    func testRejectsNULByte() {
        XCTAssertThrowsError(try PathValidator.validateRelativePath("foo\u{0}bar"))
    }

    func testRejectsBackslash() {
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a\\b"))
    }

    func testRejectsEmptyComponents() {
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a//b"))
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a/"))
    }

    // MARK: - resolveSafely

    func testResolveSafelyAcceptsContainedPath() throws {
        let root = URL(fileURLWithPath: "/tmp/tide-test")
        let url = try PathValidator.resolveSafely(relativePath: "sub/file.txt", syncRoot: root)
        XCTAssertEqual(url.standardizedFileURL.path, "/tmp/tide-test/sub/file.txt")
    }

    func testResolveSafelyRejectsEscapingPath() {
        let root = URL(fileURLWithPath: "/tmp/tide-test")
        // validateRelativePath が ".." を弾くので、表記上 dotdot を経由しない場合だけ二段目に到達する
        XCTAssertThrowsError(try PathValidator.resolveSafely(relativePath: "../escape", syncRoot: root))
    }

    // MARK: - validateShardId

    func testValidShardId() throws {
        try PathValidator.validateShardId("00")
        try PathValidator.validateShardId("a3")
        try PathValidator.validateShardId("ff")
    }

    func testInvalidShardId() {
        XCTAssertThrowsError(try PathValidator.validateShardId(""))
        XCTAssertThrowsError(try PathValidator.validateShardId("0"))      // 1 文字
        XCTAssertThrowsError(try PathValidator.validateShardId("aaa"))    // 3 文字
        XCTAssertThrowsError(try PathValidator.validateShardId("AA"))     // 大文字
        XCTAssertThrowsError(try PathValidator.validateShardId(".."))     // パストラバーサル
        XCTAssertThrowsError(try PathValidator.validateShardId("a/"))
        XCTAssertThrowsError(try PathValidator.validateShardId("g0"))     // 範囲外
        XCTAssertThrowsError(try PathValidator.validateShardId("0z"))
    }
}
