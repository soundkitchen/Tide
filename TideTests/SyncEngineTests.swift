import XCTest
@testable import Tide

/// `SyncEngine` の純粋な静的ヘルパ（不安定ファイル延期のバックオフ/警告閾値）の回帰固定。
/// give-up カウント（attempts）に載せない代わりに pendingAge を基準にする設計を固定する。
final class SyncEngineTests: XCTestCase {
    func testUnstableRetryDelayIsProportionalAndClamped() {
        // 最小: 書込が落ち着く最短待ち（quiescence）まで。
        XCTAssertEqual(SyncEngine.unstableRetryDelay(pendingAge: 0), 3)
        XCTAssertEqual(SyncEngine.unstableRetryDelay(pendingAge: 1), 3)
        // 比例: pendingAge をそのまま間隔に（倍々に伸びる領域）。
        XCTAssertEqual(SyncEngine.unstableRetryDelay(pendingAge: 10), 10)
        XCTAssertEqual(SyncEngine.unstableRetryDelay(pendingAge: 200), 200)
        // 上限: 300s でクランプ（巨大ファイルの無駄な全読みを頻発させない）。
        XCTAssertEqual(SyncEngine.unstableRetryDelay(pendingAge: 1000), 300)
    }

    func testShouldWarnUnstableCrossesThreshold() {
        XCTAssertFalse(SyncEngine.shouldWarnUnstable(pendingAge: 0))
        XCTAssertFalse(SyncEngine.shouldWarnUnstable(pendingAge: 29))
        XCTAssertTrue(SyncEngine.shouldWarnUnstable(pendingAge: 30))
        XCTAssertTrue(SyncEngine.shouldWarnUnstable(pendingAge: 100))
    }
}
