import XCTest
import TideCore

/// `ConditionalRetryPolicy` の遅延計算を回帰固定する（Issue #91）。
/// 「指数逓増 → 上限で刈る → ±25% ジッタ」の帯域が崩れると、バースト時の再衝突位相が
/// 揃って CAS 枯渇が再発する（ジッタ喪失）か、deleteItem の「数秒以内」契約を超える
/// （上限喪失）ため、境界を数値で固定する。
final class ConditionalRetryPolicyTests: XCTestCase {
    /// 各 attempt の遅延が「min(base × 2^attempt, max) ± 25%」の帯域に収まる。
    func testDelayGrowsExponentiallyCappedWithJitterBand() {
        let policy = ConditionalRetryPolicy(
            attempts: 8, baseDelayNanos: 100, maxDelayNanos: 1_600
        )
        for attempt in 0..<policy.attempts {
            let expected = min(UInt64(100) << UInt64(attempt), 1_600)
            let delay = policy.delayNanos(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(
                delay, expected - expected / 4, "attempt \(attempt): lower band"
            )
            XCTAssertLessThanOrEqual(
                delay, expected + expected / 4, "attempt \(attempt): upper band"
            )
        }
    }

    /// 上限到達後は attempt が進んでも上限帯域に留まる（実運用 .index の実値で確認）。
    func testProductionIndexPolicyStaysWithinCap() {
        let policy = ConditionalRetryPolicy.index
        for attempt in 0..<policy.attempts {
            let delay = policy.delayNanos(forAttempt: attempt)
            XCTAssertLessThanOrEqual(
                delay, policy.maxDelayNanos + policy.maxDelayNanos / 4
            )
        }
    }

    /// base = 0（テスト用の遅延ゼロポリシー）は常に 0 を返す。
    func testZeroBaseYieldsZeroDelay() {
        let policy = ConditionalRetryPolicy(attempts: 5, baseDelayNanos: 0, maxDelayNanos: 0)
        for attempt in 0..<policy.attempts {
            XCTAssertEqual(policy.delayNanos(forAttempt: attempt), 0)
        }
    }

    /// 大きな attempt でもオーバーフローせず上限帯域に収まる（min(attempt, 16) ガード）。
    func testLargeAttemptDoesNotOverflow() {
        let policy = ConditionalRetryPolicy(
            attempts: 100, baseDelayNanos: 1_000_000_000, maxDelayNanos: 2_000_000_000
        )
        let delay = policy.delayNanos(forAttempt: 99)
        XCTAssertLessThanOrEqual(delay, policy.maxDelayNanos + policy.maxDelayNanos / 4)
    }
}
