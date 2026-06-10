import XCTest
@testable import Tide

/// 帯域制御（サブ E）の網羅。純粋関数 `TokenBucket` を時刻注入で決定的に検証し（大半）、
/// 末尾で `RateLimiter` actor の無制限即返り・`setRate` を薄く通す。ファイル名と一致させて
/// `RateLimiterTests`（PR #15 レビュー nit-4）。
final class RateLimiterTests: XCTestCase {

    // MARK: - 無制限

    func testUnlimitedNeverWaits() {
        var b = TokenBucket(ratePerSec: 0, now: 0)
        XCTAssertEqual(b.reserve(1_000_000_000, now: 0), 0)
        XCTAssertEqual(b.reserve(1_000_000_000, now: 0), 0, "無制限は何バイトでも即時")
    }

    func testNegativeRateIsUnlimited() {
        var b = TokenBucket(ratePerSec: -5, now: 0)
        XCTAssertEqual(b.ratePerSec, 0, "負レートは 0（無制限）に正規化")
        XCTAssertEqual(b.reserve(10_000, now: 0), 0)
    }

    // MARK: - 基本の予約と待ち

    func testInitialBurstConsumedWithoutWaiting() {
        // burst = rate = 1000 bytes（1 秒ぶん）。初期トークンは満タン。
        var b = TokenBucket(ratePerSec: 1000, now: 0)
        XCTAssertEqual(b.reserve(1000, now: 0), 0, "初期バースト 1 秒ぶんは待たず消費")
    }

    func testWaitProportionalToDeficit() {
        var b = TokenBucket(ratePerSec: 1000, now: 0)
        _ = b.reserve(1000, now: 0)               // 残高 0
        let wait = b.reserve(500, now: 0)         // 500 不足 → 0.5s
        XCTAssertEqual(wait, 0.5, accuracy: 1e-9)
    }

    func testRefillOverTimeReducesWait() {
        var b = TokenBucket(ratePerSec: 1000, now: 0)
        _ = b.reserve(1000, now: 0)               // 残高 0
        // 0.5 秒経過で 500 補充 → 次の 1000 要求は 500 不足 → 0.5s 待ち
        let wait = b.reserve(1000, now: 0.5)
        XCTAssertEqual(wait, 0.5, accuracy: 1e-9)
    }

    func testRequestLargerThanBurstStillBounded() {
        var b = TokenBucket(ratePerSec: 1000, now: 0)
        // burst=1000 だが 5000 要求 → デッドロックせず比例待ち。
        // 初期トークン 1000 を引いて -4000 → 4.0s。
        let wait = b.reserve(5000, now: 0)
        XCTAssertEqual(wait, 4.0, accuracy: 1e-9)
    }

    // MARK: - 並行（負残高の累積＝公平性）

    func testConcurrentReservesAccumulateDebt() {
        var b = TokenBucket(ratePerSec: 1000, now: 0)
        let w1 = b.reserve(1000, now: 0)          // 残高 0、待ち 0
        let w2 = b.reserve(1000, now: 0)          // 残高 -1000、待ち 1.0s
        let w3 = b.reserve(1000, now: 0)          // 残高 -2000、待ち 2.0s
        XCTAssertEqual(w1, 0, accuracy: 1e-9)
        XCTAssertEqual(w2, 1.0, accuracy: 1e-9)
        XCTAssertEqual(w3, 2.0, accuracy: 1e-9, "後続は先行分の負債も含めて待つ＝合計が律速される")
    }

    // MARK: - バースト上限（アイドルで貯めすぎない）

    func testIdleCreditCappedAtBurst() {
        var b = TokenBucket(ratePerSec: 1000, now: 0)
        _ = b.reserve(1000, now: 0)               // 残高 0
        // 10 秒アイドル: 補充は burst(=1000) で頭打ち。10_000 にはならない。
        let wait = b.reserve(2000, now: 10)
        // 補充後トークン 1000、2000 要求 → -1000 → 1.0s
        XCTAssertEqual(wait, 1.0, accuracy: 1e-9, "アイドル蓄積は burst で cap")
    }

    // MARK: - レート変更

    func testSetRateUnlimitedToLimitedStartsWithBurst() {
        var b = TokenBucket(ratePerSec: 0, now: 0)
        b.setRate(1000, now: 5)
        XCTAssertEqual(b.ratePerSec, 1000)
        XCTAssertEqual(b.reserve(1000, now: 5), 0, "無制限→制限は 1 秒ぶんから開始")
        XCTAssertEqual(b.reserve(1, now: 5), 0.001, accuracy: 1e-9)
    }

    func testSetRateLimitedToUnlimited() {
        var b = TokenBucket(ratePerSec: 1000, now: 0)
        _ = b.reserve(1000, now: 0)
        b.setRate(0, now: 0)
        XCTAssertEqual(b.reserve(10_000_000, now: 0), 0, "無制限化で待ちなし")
    }

    func testSetRateClampsCarriedTokensToNewBurst() {
        var b = TokenBucket(ratePerSec: 10_000, now: 0)   // burst 10_000、満タン
        b.setRate(1000, now: 0)                            // 新 burst 1000 へ縮小
        // 持ち越しは min(10_000, 1000)=1000。1000 要求は待ち 0、その後 1 で 0.001s。
        XCTAssertEqual(b.reserve(1000, now: 0), 0)
        XCTAssertEqual(b.reserve(1, now: 0), 0.001, accuracy: 1e-9)
    }

    // MARK: - actor の薄い確認

    func testRateLimiterUnlimitedAcquireReturnsImmediately() async {
        let limiter = RateLimiter(ratePerSec: 0)
        await limiter.acquire(50_000_000)          // 無制限なので待たない
        let rate = await limiter.ratePerSec
        XCTAssertEqual(rate, 0)
    }

    func testRateLimiterSetRate() async {
        let limiter = RateLimiter(ratePerSec: 0)
        await limiter.setRate(2_000_000)
        let rate = await limiter.ratePerSec
        XCTAssertEqual(rate, 2_000_000)
    }
}
