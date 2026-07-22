import XCTest
@testable import Tide

/// fpOnly の S3 内復元前の kind 衝突チェック（`VersionHistoryModel.hasKindConflict`・
/// PR #77 レビュー低 1）の純粋判定を固定する。
final class VersionHistoryKindConflictTests: XCTestCase {

    func testPlainFileRestoreIsNotConflict() {
        // path 自身が現在ファイルとして存在するのは通常の上書き復元 = 衝突ではない。
        XCTAssertFalse(VersionHistoryModel.hasKindConflict(
            path: "a/b.txt", syncedPaths: ["a/b.txt", "c.txt"]
        ))
    }

    func testPathCurrentlyDirectoryIsConflict() {
        // 配下に同期済みファイルがある = path は現在ディレクトリ。
        XCTAssertTrue(VersionHistoryModel.hasKindConflict(
            path: "foo", syncedPaths: ["foo/bar.txt"]
        ))
        XCTAssertTrue(VersionHistoryModel.hasKindConflict(
            path: "a/b", syncedPaths: ["a/b/c/d.txt"]
        ))
    }

    func testAncestorCurrentlyFileIsConflict() {
        XCTAssertTrue(VersionHistoryModel.hasKindConflict(
            path: "a/b/c.txt", syncedPaths: ["a/b"]
        ))
        XCTAssertTrue(VersionHistoryModel.hasKindConflict(
            path: "a/b/c.txt", syncedPaths: ["a"]
        ))
    }

    func testSimilarPrefixIsNotConflict() {
        // "foo" に対する "foobar/…" や "foo.txt" は別パス（区切りが違う）= 非衝突。
        XCTAssertFalse(VersionHistoryModel.hasKindConflict(
            path: "foo", syncedPaths: ["foobar/baz.txt", "foo.txt"]
        ))
        // 祖先判定も同様（"a/b" に対する "a/bc" は非衝突）。
        XCTAssertFalse(VersionHistoryModel.hasKindConflict(
            path: "a/b/c.txt", syncedPaths: ["a/bc"]
        ))
    }

    func testEmptyListSkipsCheck() {
        // 一覧未ロードは素通し（ベストエフォート = ガード無しでもデータ損失は無い）。
        XCTAssertFalse(VersionHistoryModel.hasKindConflict(path: "foo", syncedPaths: []))
    }
}
