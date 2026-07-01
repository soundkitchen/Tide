import XCTest
import TideCore
@testable import Tide

/// `RemoteOpGate`（pull / restore 直列化の単一ゲート・#34 / D5）の不変条件を固定する。
/// load-bearing なのは「同時保持は高々 1（相互排他）」と「待機が必ず起こされる（lost wakeup なし）」。
@MainActor
final class RemoteOpGateTests: XCTestCase {

    /// tryAcquire は空きなら取得・保持中なら false。release で再び取得可能。
    func testTryAcquireIsMutuallyExclusive() {
        let gate = RemoteOpGate()
        XCTAssertTrue(gate.tryAcquire())   // 空き → 取得
        XCTAssertFalse(gate.tryAcquire())  // 保持中 → 失敗（待たない）
        gate.release()
        XCTAssertTrue(gate.tryAcquire())   // 解放後 → 再取得
        gate.release()
    }

    /// 待機者がいない release は単に空きへ戻す（取りこぼし・二重解放しない）。
    func testReleaseWithoutWaitersFrees() {
        let gate = RemoteOpGate()
        XCTAssertTrue(gate.tryAcquire())
        gate.release()
        XCTAssertTrue(gate.tryAcquire())
        gate.release()
    }

    /// acquire は保持中サスペンドし、release で起こされて取得する。
    func testAcquireWaitsUntilReleased() async {
        let gate = RemoteOpGate()
        XCTAssertTrue(gate.tryAcquire())   // 保持

        let signal = Signal()
        let waiter = Task { @MainActor in
            await gate.acquire()
            await signal.fire()
        }
        // 保持中はまだ起きない。
        await Task.yield()
        let firedBefore = await signal.fired
        XCTAssertFalse(firedBefore)

        gate.release()                     // 待機者へ所有権を引き渡す
        await waiter.value
        let firedAfter = await signal.fired
        XCTAssertTrue(firedAfter)

        // 引き渡しで lock は保持されたまま ＝ 直後の tryAcquire は失敗する。
        XCTAssertFalse(gate.tryAcquire())
        gate.release()
        XCTAssertTrue(gate.tryAcquire())
        gate.release()
    }

    /// 多数の並行 acquire でも同時保持は高々 1（相互排他）かつ全員が完走する（lost wakeup なし）。
    /// クリティカルセクション内に await を挟み、ゲートが無ければ複数が同時入場しうる状況を作る。
    func testConcurrentAcquiresAreMutuallyExclusive() async {
        let gate = RemoteOpGate()
        let counter = Counter()
        let n = 20

        var tasks: [Task<Void, Never>] = []
        for _ in 0..<n {
            tasks.append(Task { @MainActor in
                await gate.acquire()
                await counter.enter()
                await Task.yield()        // 保持中に他タスクへ実行機会を与える
                await counter.leave()
                gate.release()
                await counter.complete()
            })
        }
        for t in tasks { await t.value }

        let maxActive = await counter.maxActive
        let completed = await counter.completed
        XCTAssertEqual(maxActive, 1, "同時保持が 1 を超えた（相互排他違反）")
        XCTAssertEqual(completed, n, "完走しない待機者がある（lost wakeup）")
    }

    // MARK: - helpers

    /// テスト用の単発フラグ（@Sendable クロージャから安全に触るため actor 隔離）。
    private actor Signal {
        private(set) var fired = false
        func fire() { fired = true }
    }

    /// 相互排他の観測用カウンタ（同上）。
    private actor Counter {
        private var active = 0
        private(set) var maxActive = 0
        private(set) var completed = 0
        func enter() { active += 1; maxActive = max(maxActive, active) }
        func leave() { active -= 1 }
        func complete() { completed += 1 }
    }
}
