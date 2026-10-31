import XCTest
import TideCore
@testable import Tide

/// `FPEventNoticeWatcher`（Issue #147・FP 拡張イベントの新着 → OS 通知）の単体テスト。
/// 新着の取り出し（2 本のカーソル・印・再送される種類の重複除去と上限）、まとめ方、
/// stat 署名のゲートと改名カーソルの保存を固定する。
@MainActor
final class FPEventNoticeWatcherTests: XCTestCase {

    private func record(
        _ timestamp: Double, path: String? = nil, details: String? = nil, notice: FPEventNotice? = nil,
        eventType: SyncLogEventType = .info
    ) -> FPEventRecord {
        FPEventRecord(
            timestamp: timestamp, bucket: "b", eventType: eventType.rawValue, path: path, message: "m",
            details: details, notice: notice?.rawValue)
    }

    private func cursors(_ created: Double, _ renamed: Double) -> FPEventNoticeWatcher.Cursors {
        FPEventNoticeWatcher.Cursors(sinceLaunch: created, saved: renamed)
    }

    // MARK: - notices(in:after:notified:)

    /// カーソル以前のイベントは通知せず、カーソルは印の無いものを含めて最新まで進む。
    func testOnlyRecordsAfterCursorAndCursorsAdvance() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(1, path: "old-link", notice: .symbolicLink),
                record(5, path: "new-link", notice: .symbolicLink),
                record(7, path: "plain.txt"),
            ],
            after: cursors(2, 2), state: &state)
        XCTAssertEqual(result.events, [.notBackedUp(path: "new-link", reason: .symbolicLink)])
        XCTAssertEqual(result.cursors, cursors(7, 7))
    }

    /// 新着が無ければカーソルは動かない。
    func testCursorsUnchangedWithoutNewRecords() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [record(1, path: "a", notice: .symbolicLink)], after: cursors(3, 3), state: &state)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursors, cursors(3, 3))
    }

    /// 改名は保存した位置（起動前でもよい）から、作成時の除外は起動時刻から知らせる（PR #149 指摘 2）。
    func testRenamesUseSavedCursorAndCreationsUseLaunchCursor() {
        var state = FPEventNoticeWatcher.State()
        // 保存位置 = 10・起動 = 100。50 は「アプリが止まっていた間」。
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(5, path: "a.txt", details: "a.pem", notice: .renamedFileExcluded),
                record(50, path: "b.txt", details: "b.pem", notice: .renamedFileExcluded),
                record(50, path: "link", notice: .symbolicLink),
                record(120, path: "keys", details: ".ssh", notice: .renamedFolderExcluded),
            ],
            after: cursors(100, 10), state: &state)
        XCTAssertEqual(result.events, [
            .notBackedUp(path: "b.pem", reason: .renamedFileExcluded),
            .notBackedUp(path: ".ssh", reason: .renamedFolderExcluded),
        ])
        XCTAssertEqual(result.cursors, cursors(120, 120))
    }

    /// 再送される種類（作成時の除外）は同じアイテムを 1 回だけ。呼び出しをまたいでも同じ。
    func testResentKindsAreNotifiedOnce() {
        var state = FPEventNoticeWatcher.State()
        let first = FPEventNoticeWatcher.notices(
            in: [
                record(1, details: "a/b\\c.txt", notice: .unsyncableName),
                record(2, details: "a/b\\c.txt", notice: .unsyncableName),
                record(3, path: "link", notice: .symbolicLink),
            ],
            after: cursors(0, 0), state: &state)
        XCTAssertEqual(first.events, [
            .notBackedUp(path: "a/b\\c.txt", reason: .unsyncableName),
            .notBackedUp(path: "link", reason: .symbolicLink),
        ])
        let resent = FPEventNoticeWatcher.notices(
            in: [record(4, details: "a/b\\c.txt", notice: .unsyncableName),
                 record(5, path: "link", notice: .symbolicLink)],
            after: first.cursors, state: &state)
        XCTAssertTrue(resent.events.isEmpty)
        XCTAssertEqual(resent.cursors, cursors(5, 5))
    }

    /// 「通知済み」の記録は上限に達したら空にする（その後の再送はもう一度知らせる）。
    func testNotifiedKeysAreClearedAtCap() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(1, path: "l1", notice: .symbolicLink),
                record(2, path: "l2", notice: .symbolicLink),
                record(3, path: "l1", notice: .symbolicLink),
            ],
            after: cursors(0, 0), state: &state, maxNotifiedKeys: 2)
        XCTAssertEqual(result.events.count, 3, "上限で空にした後の l1 はもう一度知らせる")
        XCTAssertEqual(state.notified, ["symbolicLink:l1"])
    }

    /// 改名の除外は再送されないので、同じ名前でも毎回知らせる。名前は details（新しい名前）。
    func testRenameKindsAreNotifiedEveryTime() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(1, path: "a.txt", details: "a.env", notice: .renamedFileExcluded),
                record(2, path: "a.txt", details: "a.env", notice: .renamedFileExcluded),
                record(3, path: "keys", details: ".ssh", notice: .renamedFolderExcluded),
            ],
            after: cursors(0, 0), state: &state)
        XCTAssertEqual(result.events, [
            .notBackedUp(path: "a.env", reason: .renamedFileExcluded),
            .notBackedUp(path: "a.env", reason: .renamedFileExcluded),
            .notBackedUp(path: ".ssh", reason: .renamedFolderExcluded),
        ])
    }

    /// 名前が取れない印つきレコード（壊れた行）は通知しない。カーソルは進める。
    func testNoticeWithoutSubjectIsSkipped() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [record(1, path: nil, details: nil, notice: .unsyncableName),
                 record(2, path: "", notice: .symbolicLink)],
            after: cursors(0, 0), state: &state)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursors, cursors(2, 2))
    }

    // MARK: - #148: 競合コピー・サイズ超過・書込の失敗が続く

    /// 競合コピーは再送されない種類 = 保存した位置から（止まっていた間の分も）知らせ、毎回知らせる。
    func testConflictCopiesUseSavedCursor() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(5, path: "old.txt", details: "old (conflict).txt", notice: .conflictCopyCreated, eventType: .conflict),
                record(50, path: "a.txt", details: "a (conflict 1).txt", notice: .conflictCopyCreated, eventType: .conflict),
                record(120, path: "a.txt", details: "a (conflict 2).txt", notice: .conflictCopyCreated, eventType: .conflict),
            ],
            after: cursors(100, 10), state: &state)
        XCTAssertEqual(result.events, [
            .conflictCopyCreated(path: "a.txt", localCopyPath: "a (conflict 1).txt"),
            .conflictCopyCreated(path: "a.txt", localCopyPath: "a (conflict 2).txt"),
        ])
    }

    /// サイズ超過は再送される種類 = 起動後の分を、同じファイルは 1 回だけ知らせる。
    func testFileTooLargeIsNotifiedOncePerLaunch() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(50, path: "big.mov", notice: .fileTooLarge, eventType: .error),
                record(110, path: "big.mov", notice: .fileTooLarge, eventType: .error),
                record(120, path: "big.mov", notice: .fileTooLarge, eventType: .error),
            ],
            after: cursors(100, 100), state: &state)
        XCTAssertEqual(result.events, [.fileTooLarge(path: "big.mov")])
    }

    /// 上限を上げて一度上がったら、同じ起動中にまた上限を超えたときにもう一度知らせる（PR #160 レビュー指摘 5）。
    func testSuccessAllowsFileTooLargeAgain() {
        var state = FPEventNoticeWatcher.State()
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(110, path: "big.mov", notice: .fileTooLarge, eventType: .error),
                record(120, path: "big.mov", eventType: .upload),
                record(130, path: "big.mov", notice: .fileTooLarge, eventType: .error),
            ],
            after: cursors(100, 100), state: &state)
        XCTAssertEqual(result.events, [.fileTooLarge(path: "big.mov"), .fileTooLarge(path: "big.mov")])
    }

    /// 書込の失敗は同じパスで閾値の回数に達したら 1 回だけ知らせる。回数は呼び出しをまたいで数える。
    func testWriteFailuresAreNotifiedAtThreshold() {
        var state = FPEventNoticeWatcher.State()
        let first = FPEventNoticeWatcher.notices(
            in: (1...2).map { record(Double($0), path: "a.txt", notice: .writeFailed, eventType: .error) },
            after: cursors(0, 0), state: &state, failureThreshold: 3)
        XCTAssertTrue(first.events.isEmpty)
        let second = FPEventNoticeWatcher.notices(
            in: (3...5).map { record(Double($0), path: "a.txt", notice: .writeFailed, eventType: .error) }
                + [record(6, path: "b.txt", notice: .writeFailed, eventType: .error)],
            after: first.cursors, state: &state, failureThreshold: 3)
        XCTAssertEqual(second.events, [.writeKeepsFailing(path: "a.txt")], "3 回目で 1 回だけ・b.txt はまだ 1 回")
        XCTAssertEqual(state.failureCounts, ["a.txt": 5, "b.txt": 1])
    }

    /// そのパスの書込が成功したら数え直し、また続けて失敗したらもう一度知らせる。
    func testSuccessResetsWriteFailureCount() {
        var state = FPEventNoticeWatcher.State()
        let failures = { (from: Int) in
            (from..<(from + 2)).map { self.record(Double($0), path: "a.txt", notice: .writeFailed, eventType: .error) }
        }
        let result = FPEventNoticeWatcher.notices(
            in: failures(1)
                + [record(3, path: "a.txt", eventType: .upload)]
                + [record(4, path: "a.txt", notice: .writeFailed, eventType: .error)]
                + [record(5, path: "a.txt", eventType: .move)]
                + failures(6),
            after: cursors(0, 0), state: &state, failureThreshold: 2)
        XCTAssertEqual(result.events, [.writeKeepsFailing(path: "a.txt"), .writeKeepsFailing(path: "a.txt")])
        XCTAssertTrue(
            FPEventNoticeWatcher.notices(
                in: [record(8, path: "a.txt", notice: .writeFailed, eventType: .error)],
                after: result.cursors, state: &state, failureThreshold: 2
            ).events.isEmpty,
            "知らせたあとは成功するまで知らせない")
    }

    /// 数えるのは起動後の失敗だけ（古い失敗で後日 1 回の失敗から知らせない・PR #160 レビュー指摘 6）。
    func testWriteFailuresBeforeLaunchAreNotCounted() {
        var state = FPEventNoticeWatcher.State()
        let beforeLaunch = FPEventNoticeWatcher.notices(
            in: (1...4).map { record(Double($0), path: "a.txt", notice: .writeFailed, eventType: .error) },
            after: cursors(100, 100), state: &state, failureThreshold: 3)
        XCTAssertTrue(beforeLaunch.events.isEmpty)
        XCTAssertEqual(state.failureCounts, [:])
        let afterLaunch = FPEventNoticeWatcher.notices(
            in: (110...112).map { record(Double($0), path: "a.txt", notice: .writeFailed, eventType: .error) },
            after: cursors(100, 100), state: &state, failureThreshold: 3)
        XCTAssertEqual(afterLaunch.events, [.writeKeepsFailing(path: "a.txt")], "起動後の 3 回目で知らせる")
    }

    /// 失敗の回数の記録も上限に達したら空にする。
    func testFailureCountsAreClearedAtCap() {
        var state = FPEventNoticeWatcher.State()
        _ = FPEventNoticeWatcher.notices(
            in: ["a", "b", "c"].map { record(1, path: $0, notice: .writeFailed, eventType: .error) },
            after: cursors(0, 0), state: &state, maxNotifiedKeys: 2, failureThreshold: 5)
        XCTAssertEqual(state.failureCounts, ["c": 1])
    }

    // MARK: - batched（PR #149 指摘 1）

    func testBatchedKeepsUpToLimit() {
        let events: [NotificationEvent] = (1...3).map { .notBackedUp(path: "l\($0)", reason: .symbolicLink) }
        XCTAssertEqual(FPEventNoticeWatcher.batched(events, limit: 3), events)
        XCTAssertEqual(FPEventNoticeWatcher.batched([], limit: 3), [])
    }

    func testBatchedSummarizesTheRest() {
        let events: [NotificationEvent] = (1...10).map { .notBackedUp(path: "l\($0)", reason: .symbolicLink) }
        XCTAssertEqual(
            FPEventNoticeWatcher.batched(events, limit: 3),
            Array(events.prefix(3)) + [.notBackedUpMore(count: 7)])
    }

    /// まとめは組ごと: バックアップされない出来事（サイズ超過を含む）と失敗が続く出来事を別々に数え、
    /// 競合コピーはまとめない。
    func testBatchedGroupsByKindAndNeverBatchesConflicts() {
        let notBackedUp: [NotificationEvent] =
            (1...3).map { .notBackedUp(path: "l\($0)", reason: .symbolicLink) } + [.fileTooLarge(path: "big")]
        let failing: [NotificationEvent] = (1...5).map { .writeKeepsFailing(path: "f\($0)") }
        let conflicts: [NotificationEvent] = (1...4).map { .conflictCopyCreated(path: "c\($0)", localCopyPath: "") }
        XCTAssertEqual(
            FPEventNoticeWatcher.batched(notBackedUp + failing + conflicts, limit: 3),
            Array(notBackedUp.prefix(3)) + Array(failing.prefix(3)) + conflicts
                + [.notBackedUpMore(count: 1), .writeKeepsFailingMore(count: 2)])
    }

    // MARK: - checkOnce（差分読み・起動時刻・改名カーソルの保存）

    /// 差分読みの代役: 渡された位置を記録し、たまった新着を返して空にする。位置は読んだ件数。
    private final class FakeLog: @unchecked Sendable {
        var pending: [FPEventRecord] = []
        var positionsAsked: [FPEventLog.ReadPosition?] = []
        private var count: UInt64 = 0

        func readNew(_ position: FPEventLog.ReadPosition?)
            -> (records: [FPEventRecord], position: FPEventLog.ReadPosition?) {
            positionsAsked.append(position)
            let records = pending
            pending = []
            count += UInt64(records.count)
            return (records, FPEventLog.ReadPosition(inode: 1, offset: count))
        }
    }

    /// 起動時刻より前の作成時の除外は通知しない。2 回目からは前回の位置を渡して新着だけを読む。
    /// 改名カーソルは進んだときだけ保存する。
    func testCheckOnceReadsNewRecordsAndPersistsRenamedCursor() async {
        let log = FakeLog()
        var posted: [NotificationEvent] = []
        var saved: [Double] = []
        let watcher = FPEventNoticeWatcher(
            startedAt: Date(timeIntervalSince1970: 100),
            savedCursor: 40,
            readNew: { log.readNew($0) },
            saveCursor: { saved.append($0) },
            post: { posted.append($0) })

        log.pending = [
            record(30, path: "x.txt", details: "x.pem", notice: .renamedFileExcluded),  // 保存位置より前
            record(50, path: "before-launch", notice: .symbolicLink),                   // 起動前の作成
            record(60, path: "y.txt", details: "y.pem", notice: .renamedFileExcluded),  // 停止中の改名
        ]
        await watcher.checkOnce()
        XCTAssertEqual(posted, [.notBackedUp(path: "y.pem", reason: .renamedFileExcluded)])
        XCTAssertEqual(saved, [60])

        await watcher.checkOnce()
        XCTAssertEqual(posted.count, 1, "新着が無ければ通知しない")
        XCTAssertEqual(saved, [60])

        log.pending = [record(150, path: "after-launch", notice: .symbolicLink)]
        await watcher.checkOnce()
        XCTAssertEqual(posted.last, .notBackedUp(path: "after-launch", reason: .symbolicLink))
        XCTAssertEqual(saved, [60, 150])
        XCTAssertEqual(log.positionsAsked, [
            nil,
            FPEventLog.ReadPosition(inode: 1, offset: 3),
            FPEventLog.ReadPosition(inode: 1, offset: 3),
        ], "初回は全部、以後は前回の位置から読む")
    }

    /// 確認の途中で頼まれた確認は捨てず、終わったあとにもう一度読む（その間の追記を読み逃さない）。
    func testCheckRequestedDuringCheckRereadsAfterward() async {
        final class SlowLog: @unchecked Sendable {
            var reads = 0
            var gate: CheckedContinuation<Void, Never>?
            var started: CheckedContinuation<Void, Never>?
        }
        let log = SlowLog()
        let watcher = FPEventNoticeWatcher(
            savedCursor: nil,
            readNew: { position in
                log.reads += 1
                if log.reads == 1 {
                    await withCheckedContinuation { continuation in
                        log.gate = continuation
                        log.started?.resume()
                    }
                }
                return ([], position)
            },
            saveCursor: { _ in },
            post: { _ in })

        let first = Task { await watcher.checkOnce() }
        await withCheckedContinuation { log.started = $0 }
        await watcher.checkOnce()  // 1 回目の途中 = すぐ戻り、再確認を頼むだけ
        XCTAssertEqual(log.reads, 1)
        log.gate?.resume()
        await first.value
        XCTAssertEqual(log.reads, 2, "途中で頼まれた分をもう一度読む")
    }

    /// 起動すると追記の通知を受け取る登録を作り、通知が来たら読む。止めると登録を手放す。
    func testStartObservesChangeNotifications() async throws {
        final class Registry: @unchecked Sendable {
            var handler: (@Sendable () -> Void)?
            var token: NSObject?
        }
        let registry = Registry()
        let log = FakeLog()
        var posted: [NotificationEvent] = []
        let watcher = FPEventNoticeWatcher(
            intervalSeconds: 3600,
            startedAt: Date(timeIntervalSince1970: 0),
            savedCursor: nil,
            readNew: { log.readNew($0) },
            saveCursor: { _ in },
            post: { posted.append($0) },
            observeChanges: { handler in
                registry.handler = handler
                let token = NSObject()
                registry.token = token
                return token
            })
        watcher.start()
        XCTAssertNotNil(registry.handler)
        // 初回の確認が終わるのを待つ
        while log.positionsAsked.isEmpty { await Task.yield() }

        log.pending = [record(10, path: "link", notice: .symbolicLink)]
        registry.handler?()
        for _ in 0..<1000 where posted.isEmpty { await Task.yield() }
        XCTAssertEqual(posted, [.notBackedUp(path: "link", reason: .symbolicLink)])

        weak var weakToken = registry.token
        registry.token = nil
        watcher.stop()
        XCTAssertNil(weakToken, "止めると登録を手放す")
    }

    /// 保存が無いとき（初回・factoryReset 後）は、改名も起動時刻から始める。
    func testRenamedCursorStartsAtLaunchWithoutSavedValue() async {
        let log = FakeLog()
        log.pending = [record(50, path: "y.txt", details: "y.pem", notice: .renamedFileExcluded)]
        var posted: [NotificationEvent] = []
        let watcher = FPEventNoticeWatcher(
            startedAt: Date(timeIntervalSince1970: 100),
            savedCursor: nil,
            readNew: { log.readNew($0) },
            saveCursor: { _ in },
            post: { posted.append($0) })
        await watcher.checkOnce()
        XCTAssertTrue(posted.isEmpty)
    }
}
