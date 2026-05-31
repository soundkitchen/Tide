import XCTest
@testable import Tide

final class IgnoreDecisionTests: XCTestCase {
    func testHardcodedAlwaysSkipped() {
        let m = SyncIgnoreMatcher.empty
        // 追跡中でも未追跡でもハードコードは常にスキップ
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: false, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: true, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "sub/server.pem", isAlreadyTracked: true, matcher: m))
    }

    func testNegationCannotReincludeHardcoded() {
        // !.env / !*.pem を書いてもハードコードが勝つ（機密は同期されない）
        let m = SyncIgnoreMatcher.parse("!.env\n!*.pem")
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: false, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "key.pem", isAlreadyTracked: false, matcher: m))
    }

    func testUserPatternSkipsOnlyUntracked() {
        let m = SyncIgnoreMatcher.parse("*.log")
        // 未追跡（新規）→ スキップ
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: false, matcher: m))
        // 既存追跡 → スキップしない（gitignore 純正・既存は触らない）
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: true, matcher: m))
    }

    func testSyncignoreItselfNeverSkipped() {
        // どんなユーザパターンでも .syncignore 自身は除外しない（設定が消えるのを防ぐ）
        let m = SyncIgnoreMatcher.parse("*\n.syncignore")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: ".syncignore", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: ".syncignore", isAlreadyTracked: true, matcher: m))
    }

    func testNonMatchingNotSkipped() {
        let m = SyncIgnoreMatcher.parse("*.log")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "report.pdf", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "report.pdf", isAlreadyTracked: true, matcher: m))
    }
}
