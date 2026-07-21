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

    private func makeSignaler(head: FakeHead, counter: SignalCounter) -> RemoteChangeSignaler {
        RemoteChangeSignaler(
            intervalSeconds: 3600,  // タイマーはテストでは実質発火しない（checkOnce を直接駆動）
            headIndexETag: { try head.next() },
            signal: { counter.fire() }
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
