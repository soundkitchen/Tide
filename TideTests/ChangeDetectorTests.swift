import XCTest
@testable import Tide

/// `ChangeDetector`（フルスキャン / FSEvents の変更判定 + SHA ゲート）の全分岐を固定する。
/// `ThreeWayMergeTests` / `IgnoreDecisionTests` と同じ純粋関数テストのパターン。
final class ChangeDetectorTests: XCTestCase {
    private func known(
        size: Int64 = 100, mtime: Double = 1_780_000_000.789,
        sha: String = "abc", isSynced: Bool = true
    ) -> ChangeDetector.Known {
        ChangeDetector.Known(size: size, mtime: mtime, sha256: sha, isSynced: isSynced)
    }

    // MARK: - preDecision

    func testUnknownFileEnqueues() {
        XCTAssertEqual(
            ChangeDetector.preDecision(known: nil, size: 100, mtime: 1),
            .enqueue
        )
    }

    func testUnsyncedRecordEnqueues() {
        // lastSyncedAt == nil（enqueue 済みだが未同期）は従来どおり enqueue（hash 検証しない）。
        XCTAssertEqual(
            ChangeDetector.preDecision(known: known(isSynced: false), size: 100, mtime: 1_780_000_000.789),
            .enqueue
        )
    }

    func testSizeMismatchEnqueuesWithoutHash() {
        // size が違えば sha は一致し得ないので hash せず直接 enqueue（仕様と同義の最適化）。
        XCTAssertEqual(
            ChangeDetector.preDecision(known: known(size: 100), size: 101, mtime: 1_780_000_000.789),
            .enqueue
        )
    }

    func testExactMatchSkips() {
        XCTAssertEqual(
            ChangeDetector.preDecision(known: known(), size: 100, mtime: 1_780_000_000.789),
            .skip
        )
    }

    func testMtimeWithinToleranceSkips() {
        // 既存比較（abs(diff) < 0.001）と同値の境界: 0.0009 差は一致扱い。
        XCTAssertEqual(
            ChangeDetector.preDecision(known: known(), size: 100, mtime: 1_780_000_000.789 + 0.0009),
            .skip
        )
    }

    func testMtimeBeyondToleranceVerifiesHash() {
        // 0.0011 差は不一致 → size 一致なので SHA で実変更か mtime ドリフトかを判定する。
        XCTAssertEqual(
            ChangeDetector.preDecision(known: known(), size: 100, mtime: 1_780_000_000.789 + 0.0011),
            .verifyHash
        )
    }

    func testSecondPrecisionDriftVerifiesHash() {
        // 本命シナリオ: マニフェスト秒精度 mtime で汚染された DB（.0）vs ローカル stat（.789）。
        XCTAssertEqual(
            ChangeDetector.preDecision(known: known(mtime: 1_780_000_000.0), size: 100, mtime: 1_780_000_000.789),
            .verifyHash
        )
    }

    // MARK: - postHash

    func testPostHashMatchRefreshesMtimeOnly() {
        XCTAssertEqual(
            ChangeDetector.postHash(knownSha: "abc", computedSha: "abc"),
            .refreshMtimeOnly
        )
    }

    func testPostHashMismatchEnqueues() {
        XCTAssertEqual(
            ChangeDetector.postHash(knownSha: "abc", computedSha: "def"),
            .enqueue
        )
    }

    func testPostHashFailureEnqueues() {
        // hash 失敗（nil）は enqueue に倒す（従来挙動と同一: Uploader 側が delete 変換 / symlink skip）。
        XCTAssertEqual(
            ChangeDetector.postHash(knownSha: "abc", computedSha: nil),
            .enqueue
        )
    }
}
