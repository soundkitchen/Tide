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

    // MARK: - resolveForWrite（祖先 symlink 脱出: F2 / M6）

    /// テスト用に一時 syncRoot と「root の外」を指すディレクトリを用意する。
    private func makeTempDirs() throws -> (root: URL, outside: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tide-pv-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, outside)
    }

    func testResolveForWriteAcceptsRealSubdir() throws {
        let (root, _) = try makeTempDirs()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        // 実ディレクトリ配下、まだ存在しないファイル名でも通る
        let url = try PathValidator.resolveForWrite(relativePath: "sub/file.txt", syncRoot: root)
        XCTAssertEqual(url.lastPathComponent, "file.txt")
        // 祖先が一切存在しない（root 直下に未作成ディレクトリ）でも、最深既存祖先 = root なので通る
        XCTAssertNoThrow(try PathValidator.resolveForWrite(relativePath: "newdir/deep/x", syncRoot: root))
    }

    func testResolveForWriteRejectsAncestorSymlinkEscape() throws {
        let (root, outside) = try makeTempDirs()
        // root/evil → outside（root の外）への symlink ディレクトリ
        let link = root.appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        // 字句的には root 配下だが、祖先 symlink を辿ると outside に抜けるので拒否
        XCTAssertThrowsError(try PathValidator.resolveForWrite(relativePath: "evil/x", syncRoot: root)) { err in
            guard case PathValidator.ValidationError.escapesSyncRootViaSymlink = err else {
                return XCTFail("expected escapesSyncRootViaSymlink, got \(err)")
            }
        }
    }

    func testResolveForWriteAllowsSymlinkPointingInsideRoot() throws {
        let (root, _) = try makeTempDirs()
        let realInside = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realInside, withIntermediateDirectories: true)
        // root/alias → root/real（root 内）なら脱出にならないので許可
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realInside)
        XCTAssertNoThrow(try PathValidator.resolveForWrite(relativePath: "alias/x", syncRoot: root))
    }

    // MARK: - isSymbolicLink（アップロード直前の再チェック: F3 / L9）

    func testIsSymbolicLink() throws {
        let (root, _) = try makeTempDirs()
        let regular = root.appendingPathComponent("regular.txt")
        try Data("hi".utf8).write(to: regular)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)

        XCTAssertFalse(PathValidator.isSymbolicLink(at: regular))
        XCTAssertTrue(PathValidator.isSymbolicLink(at: link))
        // 存在しないパスは false
        XCTAssertFalse(PathValidator.isSymbolicLink(at: root.appendingPathComponent("nope")))
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
