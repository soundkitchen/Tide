import XCTest
import TideCore
@testable import Tide

/// M5 Track B: FP-only 稼働モードのリモート変更検知（`RemoteChangeSignaler`）の直接駆動テスト。
/// `checkOnce` の判定 → signal 配線を依存注入（フェイク HEAD + カウンタ）で固定する。
/// 不変条件: DB / shard_state 非接触（本型はそもそも依存を持たない = 構造的に保証）・
/// index 不在は無反応・HEAD 失敗で保持 ETag を進めない（一過性エラーで変化を取りこぼさない）。
@MainActor
final class RemoteChangeSignalerTests: XCTestCase {

    /// フェイク HEAD: 呼び出しごとに `results` を先頭から消費し、尽きたら最後の値を返し続ける。
    private final class FakeHead: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<String?, Error>]
        init(_ results: [Result<String?, Error>]) { self.results = results }
        func next() throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            let r = results.count > 1 ? results.removeFirst() : results[0]
            return try r.get()
        }
    }

    private struct HeadError: Error {}

    /// フェイク FP ドメイン有効性（Issue #82）: 呼び出しごとに `values` を先頭から消費し、
    /// 尽きたら最後の値を返し続ける（FakeHead と同型）。
    private final class FakeEnabled: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool]
        init(_ values: [Bool]) { self.values = values }
        func next() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return values.count > 1 ? values.removeFirst() : values[0]
        }
    }

    private func makeSignaler(
        head: FakeHead, counter: SignalCounter, enabled: FakeEnabled = FakeEnabled([true])
    ) -> RemoteChangeSignaler {
        RemoteChangeSignaler(
            intervalSeconds: 3600,  // タイマーはテストでは実質発火しない（checkOnce を直接駆動）
            headIndexETag: { try head.next() },
            signal: { counter.fire() },
            isFPDomainEnabled: { enabled.next() }
        )
    }

    /// 初回チェック: ベースライン確立 + 1 回 signal（アプリ停止中の変化の取り込み保険）。
    /// 以降、同一 ETag の間は signal しない。
    func testFirstCheckSignalsOnceThenQuietWhileUnchanged() async {
        let head = FakeHead([.success("etag-1")])
        let counter = SignalCounter()
        let signaler = makeSignaler(head: head, counter: counter)

        await signaler.checkOnce(reason: "test")
        XCTAssertEqual(counter.count, 1, "初回チェックでベースライン signal が出ていない")
        await signaler.checkOnce(reason: "test")
        await signaler.checkOnce(reason: "test")
        XCTAssertEqual(counter.count, 1, "ETag 不変なのに signal が出た")
    }

    /// ETag 変化で signal し、その後の不変期間は再度沈黙する。
    func testSignalsOnETagChange() async {
        let head = FakeHead([.success("etag-1"), .success("etag-1"), .success("etag-2")])
        let counter = SignalCounter()
        let signaler = makeSignaler(head: head, counter: counter)

        await signaler.checkOnce(reason: "test")  // baseline (etag-1) → signal 1
        await signaler.checkOnce(reason: "test")  // etag-1 のまま → 沈黙
        XCTAssertEqual(counter.count, 1)
        await signaler.checkOnce(reason: "test")  // etag-2 へ変化 → signal 2
        XCTAssertEqual(counter.count, 2, "ETag 変化で signal が出ていない")
        await signaler.checkOnce(reason: "test")  // etag-2 のまま → 沈黙
        XCTAssertEqual(counter.count, 2)
    }

    /// index 不在（未セットアップ / 空バケット）は無反応で、初出現を変化として拾う。
    func testAbsentIndexIsQuietUntilItAppears() async {
        let head = FakeHead([.success(nil), .success(nil), .success("etag-1")])
        let counter = SignalCounter()
        let signaler = makeSignaler(head: head, counter: counter)

        await signaler.checkOnce(reason: "test")
        await signaler.checkOnce(reason: "test")
        XCTAssertEqual(counter.count, 0, "index 不在で signal が出た")
        await signaler.checkOnce(reason: "test")  // 初出現 = 初回ベースライン signal
        XCTAssertEqual(counter.count, 1)
    }

    /// HEAD 失敗は保持 ETag を進めず signal もしない。復旧後の変化は次のチェックで必ず拾う。
    func testHeadFailureKeepsBaselineAndCatchesLaterChange() async {
        let head = FakeHead([
            .success("etag-1"),      // baseline → signal 1
            .failure(HeadError()),   // 失敗 → 沈黙・ベースライン維持
            .success("etag-2")       // 復旧 + 変化 → signal 2
        ])
        let counter = SignalCounter()
        let signaler = makeSignaler(head: head, counter: counter)

        await signaler.checkOnce(reason: "test")
        XCTAssertEqual(counter.count, 1)
        await signaler.checkOnce(reason: "test")
        XCTAssertEqual(counter.count, 1, "HEAD 失敗で signal が出た")
        await signaler.checkOnce(reason: "test")
        XCTAssertEqual(counter.count, 2, "失敗を挟んだ変化を取りこぼした")
    }

    /// 失敗 → 復旧で ETag が「初回と同じ」なら余計な signal は出ない（失敗がベースラインを
    /// 壊していない証明の対側）。
    func testRecoveryWithSameETagStaysQuiet() async {
        let head = FakeHead([
            .success("etag-1"),      // baseline → signal 1
            .failure(HeadError()),   // 失敗
            .success("etag-1")       // 復旧・不変 → 沈黙
        ])
        let counter = SignalCounter()
        let signaler = makeSignaler(head: head, counter: counter)

        await signaler.checkOnce(reason: "test")
        await signaler.checkOnce(reason: "test")
        await signaler.checkOnce(reason: "test")
        XCTAssertEqual(counter.count, 1, "復旧後の不変 ETag で余計な signal が出た")
    }

    /// UI 用の観測状態（B-1・fpOnly ポップオーバー）: 成功で lastCheckedAt 前進 + 失敗フラグ解除、
    /// signal 発火（ベースライン/変化）で lastSignaledAt 前進、失敗で lastCheckFailed のみ立つ
    /// （時刻は前進しない = 「最後に成功した観測」の意味を保つ）。
    func testObservableStateTransitions() async {
        let head = FakeHead([
            .success("etag-1"),      // baseline → checked + signaled
            .failure(HeadError()),   // 失敗 → failed 立つ・時刻は不変
            .success("etag-1"),      // 復旧・不変 → checked 前進・failed 解除・signaled 不変
            .success("etag-2")       // 変化 → signaled 前進
        ])
        let counter = SignalCounter()
        let signaler = makeSignaler(head: head, counter: counter)
        XCTAssertNil(signaler.lastCheckedAt)
        XCTAssertNil(signaler.lastSignaledAt)
        XCTAssertFalse(signaler.lastCheckFailed)

        await signaler.checkOnce(reason: "test")  // baseline
        let checked1 = signaler.lastCheckedAt
        let signaled1 = signaler.lastSignaledAt
        XCTAssertNotNil(checked1)
        XCTAssertNotNil(signaled1)
        XCTAssertFalse(signaler.lastCheckFailed)

        await signaler.checkOnce(reason: "test")  // 失敗
        XCTAssertTrue(signaler.lastCheckFailed)
        XCTAssertEqual(signaler.lastCheckedAt, checked1, "失敗で lastCheckedAt が動いた")
        XCTAssertEqual(signaler.lastSignaledAt, signaled1)

        await signaler.checkOnce(reason: "test")  // 復旧・不変
        XCTAssertFalse(signaler.lastCheckFailed, "成功で失敗フラグが解除されていない")
        XCTAssertNotEqual(signaler.lastCheckedAt, checked1, "成功で lastCheckedAt が前進していない")
        XCTAssertEqual(signaler.lastSignaledAt, signaled1, "signal なしで lastSignaledAt が動いた")

        await signaler.checkOnce(reason: "test")  // 変化
        XCTAssertNotEqual(signaler.lastSignaledAt, signaled1, "変化 signal で lastSignaledAt が前進していない")
    }

    /// FP ドメイン有効性の併観測（Issue #82）: 無効の観測で `fpDomainDisabled` が立ち、
    /// 有効へ戻る観測で解除される（エッジ検出）。既定値は false（未観測 = 無効扱いしない）。
    func testFPDomainDisabledEdgeDetection() async {
        let head = FakeHead([.success("etag-1")])
        let counter = SignalCounter()
        let enabled = FakeEnabled([true, false, false, true])
        let signaler = makeSignaler(head: head, counter: counter, enabled: enabled)
        XCTAssertFalse(signaler.fpDomainDisabled, "未観測なのに無効扱いになっている")

        await signaler.checkOnce(reason: "test")  // 有効
        XCTAssertFalse(signaler.fpDomainDisabled)
        await signaler.checkOnce(reason: "test")  // 無効を観測 → 立つ
        XCTAssertTrue(signaler.fpDomainDisabled, "無効の観測でフラグが立っていない")
        await signaler.checkOnce(reason: "test")  // 無効のまま → 維持
        XCTAssertTrue(signaler.fpDomainDisabled)
        await signaler.checkOnce(reason: "test")  // 有効へ復帰 → 解除
        XCTAssertFalse(signaler.fpDomainDisabled, "復帰でフラグが解除されていない")
    }

    /// 復帰エッジは ETag 不変でも必ず 1 回 signal する（見逃し窓の閉鎖）: 無効期間中の
    /// ETag 変化は観測だけ進み（プロダクションでは下流の isEnabled ガードで signal が no-op）、
    /// 次の変化まで取り込み契機が来ないため、復帰時に catch-up を強制する。
    func testReEnableEdgeForcesCatchUpSignal() async {
        let head = FakeHead([.success("etag-1")])
        let counter = SignalCounter()
        let enabled = FakeEnabled([true, false, true])
        let signaler = makeSignaler(head: head, counter: counter, enabled: enabled)

        await signaler.checkOnce(reason: "test")  // baseline → signal 1
        XCTAssertEqual(counter.count, 1)
        await signaler.checkOnce(reason: "test")  // 無効・ETag 不変 → 沈黙
        XCTAssertEqual(counter.count, 1)
        let signaledBefore = signaler.lastSignaledAt
        await signaler.checkOnce(reason: "test")  // 復帰・ETag 不変 → catch-up signal
        XCTAssertEqual(counter.count, 2, "復帰エッジの catch-up signal が出ていない")
        XCTAssertNotEqual(signaler.lastSignaledAt, signaledBefore, "catch-up で lastSignaledAt が前進していない")
    }

    /// 無効/復帰エッジのフック（Issue #103: OS 通知の発火/撤去の配線面）は**エッジ検出時のみ**
    /// 呼ばれる — 毎周回呼ぶと通知の連発（identifier 置換でも音は毎回鳴る）になる。
    func testFPDomainDisabledEdgeHookFiresOnEdgesOnly() async {
        let head = FakeHead([.success("etag-1")])
        let counter = SignalCounter()
        let enabled = FakeEnabled([true, false, false, true, true])
        var hookCalls: [Bool] = []
        let signaler = RemoteChangeSignaler(
            intervalSeconds: 3600,
            headIndexETag: { try head.next() },
            signal: { counter.fire() },
            isFPDomainEnabled: { enabled.next() },
            onFPDomainDisabledEdge: { hookCalls.append($0) }
        )

        await signaler.checkOnce(reason: "test")  // 有効（初回・エッジではない）
        XCTAssertEqual(hookCalls, [])
        await signaler.checkOnce(reason: "test")  // 無効エッジ
        XCTAssertEqual(hookCalls, [true], "無効エッジでフックが呼ばれていない")
        await signaler.checkOnce(reason: "test")  // 無効のまま → 呼ばない
        XCTAssertEqual(hookCalls, [true], "非エッジ周回でフックが連発している")
        await signaler.checkOnce(reason: "test")  // 復帰エッジ
        XCTAssertEqual(hookCalls, [true, false], "復帰エッジでフックが呼ばれていない")
        await signaler.checkOnce(reason: "test")  // 有効のまま → 呼ばない
        XCTAssertEqual(hookCalls, [true, false])
    }

    /// 併観測は HEAD より先に走る = HEAD 失敗（オフライン等）でも拡張 OFF に気づける。
    func testDisabledDetectionSurvivesHeadFailure() async {
        let head = FakeHead([.failure(HeadError())])
        let counter = SignalCounter()
        let enabled = FakeEnabled([false])
        let signaler = makeSignaler(head: head, counter: counter, enabled: enabled)

        await signaler.checkOnce(reason: "test")
        XCTAssertTrue(signaler.fpDomainDisabled, "HEAD 失敗時に無効検出が動いていない")
        XCTAssertTrue(signaler.lastCheckFailed)
        XCTAssertEqual(counter.count, 0)
    }

    /// start() は初回チェックを発火する（起動時のベースライン確立の配線）。stop() は冪等。
    func testStartFiresInitialCheck() async throws {
        let head = FakeHead([.success("etag-1")])
        let counter = SignalCounter()
        let signaler = makeSignaler(head: head, counter: counter)

        signaler.start()
        // 初回チェックは fire-and-forget の Task なので有界ポーリングで待つ。
        for _ in 0..<200 where counter.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(counter.count, 1, "start() が初回チェックを発火していない")
        signaler.stop()
        signaler.stop()  // 冪等
    }
}
