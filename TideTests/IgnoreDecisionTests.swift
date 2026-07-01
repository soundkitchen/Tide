import XCTest
import TideCore
@testable import Tide

final class IgnoreDecisionTests: XCTestCase {
    /// ルート直下 `.syncignore` のみの層状マッチャを組む補助。
    private func root(_ text: String) -> LayeredSyncIgnore {
        LayeredSyncIgnore(root: SyncIgnoreMatcher.parse(text))
    }

    func testHardcodedAlwaysSkipped() {
        let m = LayeredSyncIgnore.empty
        // 追跡中でも未追跡でもハードコードは常にスキップ
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: false, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: true, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "sub/server.pem", isAlreadyTracked: true, matcher: m))
    }

    func testNegationCannotReincludeHardcoded() {
        // !.env / !*.pem を書いてもハードコードが勝つ（機密は同期されない）
        let m = root("!.env\n!*.pem")
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: false, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "key.pem", isAlreadyTracked: false, matcher: m))
    }

    func testUserPatternSkipsOnlyUntracked() {
        let m = root("*.log")
        // 未追跡（新規）→ スキップ
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: false, matcher: m))
        // 既存追跡 → スキップしない（gitignore 純正・既存は触らない）
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: true, matcher: m))
    }

    func testSyncignoreItselfNeverSkipped() {
        // どんなユーザパターンでも .syncignore 自身は除外しない（設定が消えるのを防ぐ）
        let m = root("*\n.syncignore")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: ".syncignore", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: ".syncignore", isAlreadyTracked: true, matcher: m))
    }

    func testNestedSyncignoreNeverSkipped() {
        // ネストした .syncignore も自己保護（除外設定が同期から外れて消えるのを防ぐ）。
        // ルートの `*` で配下ファイルは除外されるが、各階層の .syncignore 自身は通す。
        let m = root("*")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "sub/.syncignore", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "a/b/c/.syncignore", isAlreadyTracked: false, matcher: m))
        // 名前末尾が .syncignore でも別ファイルなら自己保護しない（通常のユーザパターン判定に従う）。
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "sub/my.syncignore", isAlreadyTracked: false, matcher: m))
    }

    func testNestedHardcodedBeatsNestedSyncignore() {
        // 機密網配下（.aws/）にある .syncignore はハードコードが最優先＝スキップ（同期しない）。
        let m = LayeredSyncIgnore.empty
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".aws/.syncignore", isAlreadyTracked: false, matcher: m))
    }

    func testNestedOverrideReincludesUntracked() {
        // ルートで *.log を除外、サブディレクトリの .syncignore で再包含 → 未追跡でもスキップしない。
        let m = LayeredSyncIgnore(matchers: [
            "": SyncIgnoreMatcher.parse("*.log"),
            "keep": SyncIgnoreMatcher.parse("!*.log")
        ])
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "keep/foo.log", isAlreadyTracked: false, matcher: m))
    }

    func testNonMatchingNotSkipped() {
        let m = root("*.log")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "report.pdf", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "report.pdf", isAlreadyTracked: true, matcher: m))
    }
}
