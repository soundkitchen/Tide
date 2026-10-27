import XCTest
import TideCore
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

    /// `/` や `\` の直後に結合文字（U+0301）を付けて、書記素単位の判定から区切りや禁止文字を
    /// 隠したパス（#137）。バイト単位で見れば各ゲートに掛かるので、すべて拒否する。
    func testRejectsSeparatorsHiddenByCombiningCharacter() {
        let accent = "\u{301}"
        // バイト単位では ".." がある
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a/../\(accent)b"))
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a/./\(accent)b"))
        // 先頭の "/" = 絶対パス
        XCTAssertThrowsError(try PathValidator.validateRelativePath("/\(accent)etc/passwd"))
        // バックスラッシュ
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a\\\(accent)b"))
        // 空要素
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a//\(accent)b"))
        // 区切りと結合文字が 1 つの書記素になっているだけのパスも拒否（下流の書記素単位の分割とずれるため）
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a/\(accent)b"))
    }

    /// 結合文字そのものは普通のファイル名に含まれる（NFD の濁点・アクセント）。区切りの直後でなければ通す。
    func testAcceptsCombiningCharactersInsideComponents() throws {
        try PathValidator.validateRelativePath("caf\u{65}\u{301}/menu.txt")      // NFD の é
        try PathValidator.validateRelativePath("\u{304B}\u{3099}/\u{304B}\u{3099}.txt")  // NFD の「が」
        try PathValidator.validateRelativePath("a/.\u{301}")                       // "." ではない名前
    }

    /// 区切りの `/` が前後の文字と 1 つの書記素になる名前は、結合文字に限らず拒否する（PR #146 レビュー）。
    /// 要素の先頭に Extend / SpacingMark / ZWJ が来る場合と、フォルダ名が Prepend 文字で終わる場合。
    func testRejectsSeparatorFusedWithAdjacentCharacter() {
        XCTAssertThrowsError(try PathValidator.validateRelativePath("docs/\u{1F3FD}notes.txt"))  // 肌色修飾子だけ
        XCTAssertThrowsError(try PathValidator.validateRelativePath("docs/\u{FE0F}x"))           // 異体字セレクタ
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a/\u{200D}b"))              // ZWJ
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a/\u{093F}x"))              // デーヴァナーガリーの母音記号
        XCTAssertThrowsError(try PathValidator.validateRelativePath("a\u{0600}/b"))              // Prepend で終わるフォルダ名
    }

    /// 絵文字で始まる普通の名前は通す（修飾子・セレクタ・ZWJ は基底文字の後に付いている）。
    func testAcceptsNamesStartingWithEmoji() throws {
        try PathValidator.validateRelativePath("docs/\u{1F44D}notes.txt")                        // 👍
        try PathValidator.validateRelativePath("docs/\u{1F44D}\u{1F3FD}notes.txt")               // 👍🏽
        try PathValidator.validateRelativePath("docs/\u{2764}\u{FE0F}memo.txt")                  // ❤️
        try PathValidator.validateRelativePath("docs/\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} family")  // 👨‍👩‍👧
        try PathValidator.validateRelativePath("docs/\u{1F1EF}\u{1F1F5}trip")                    // 🇯🇵
        try PathValidator.validateRelativePath("docs/1\u{FE0F}\u{20E3}first.txt")                // 1️⃣
        try PathValidator.validateRelativePath("\u{1F4C1}/\u{1F44D}\u{1F3FD}x.txt")              // 📁/👍🏽
        try PathValidator.validateRelativePath("a/\u{0915}\u{093F}.txt")                         // कि
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

    // MARK: - isSameFileSystemObject（同期フォルダの同一性判定・PR #49 レビュー #2）

    func testSameFileSystemObjectForSameDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        // 同一パス表記
        XCTAssertTrue(PathValidator.isSameFileSystemObject(dir, dir))
        // symlink 経由の別表記（保存パスに symlink を含むケース）
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertTrue(PathValidator.isSameFileSystemObject(link, dir))
        // リネーム後の新パス（bookmark が追跡した想定）と、リネーム前実体は同一
        let renamed = base.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: renamed)
        XCTAssertTrue(PathValidator.isSameFileSystemObject(renamed, renamed))
    }

    func testDifferentDirectoriesAreNotSame() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID().uuidString)")
        let a = base.appendingPathComponent("a", isDirectory: true)
        let b = base.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        XCTAssertFalse(PathValidator.isSameFileSystemObject(a, b))
    }

    func testMissingPathIsNeverSame() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID().uuidString)")
        let a = base.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let missing = base.appendingPathComponent("missing", isDirectory: true)

        // 「同一と確認できない」は安全側（false）に倒す
        XCTAssertFalse(PathValidator.isSameFileSystemObject(a, missing))
        XCTAssertFalse(PathValidator.isSameFileSystemObject(missing, missing))
    }
}
