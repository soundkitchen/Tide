import XCTest
import TideCore
@testable import Tide

/// `FPEventNoticeWatcher`（Issue #147・FP 拡張イベントの新着 → OS 通知）の単体テスト。
/// 新着の取り出し（2 本のカーソル・印・再送される種類の重複除去と上限）、まとめ方、
/// stat 署名のゲートと改名カーソルの保存を固定する。
@MainActor
final class FPEventNoticeWatcherTests: XCTestCase {

    private func record(
        _ timestamp: Double, path: String? = nil, details: String? = nil, notice: FPEventNotice? = nil
    ) -> FPEventRecord {
        FPEventRecord(
            timestamp: timestamp, bucket: "b", eventType: "info", path: path, message: "m",
            details: details, notice: notice?.rawValue)
    }

    private func cursors(_ created: Double, _ renamed: Double) -> FPEventNoticeWatcher.Cursors {
        FPEventNoticeWatcher.Cursors(created: created, renamed: renamed)
    }

    // MARK: - notices(in:after:notified:)

    /// カーソル以前のイベントは通知せず、カーソルは印の無いものを含めて最新まで進む。
    func testOnlyRecordsAfterCursorAndCursorsAdvance() {
        var notified: Set<String> = []
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(1, path: "old-link", notice: .symbolicLink),
                record(5, path: "new-link", notice: .symbolicLink),
                record(7, path: "plain.txt"),
            ],
            after: cursors(2, 2), notified: &notified)
        XCTAssertEqual(result.events, [.notBackedUp(path: "new-link", reason: .symbolicLink)])
        XCTAssertEqual(result.cursors, cursors(7, 7))
    }

    /// 新着が無ければカーソルは動かない。
    func testCursorsUnchangedWithoutNewRecords() {
        var notified: Set<String> = []
        let result = FPEventNoticeWatcher.notices(
            in: [record(1, path: "a", notice: .symbolicLink)], after: cursors(3, 3), notified: &notified)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursors, cursors(3, 3))
    }

    /// 改名は保存した位置（起動前でもよい）から、作成時の除外は起動時刻から知らせる（PR #149 指摘 2）。
    func testRenamesUseSavedCursorAndCreationsUseLaunchCursor() {
        var notified: Set<String> = []
        // 保存位置 = 10・起動 = 100。50 は「アプリが止まっていた間」。
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(5, path: "a.txt", details: "a.pem", notice: .renamedFileExcluded),
                record(50, path: "b.txt", details: "b.pem", notice: .renamedFileExcluded),
                record(50, path: "link", notice: .symbolicLink),
                record(120, path: "keys", details: ".ssh", notice: .renamedFolderExcluded),
            ],
            after: cursors(100, 10), notified: &notified)
        XCTAssertEqual(result.events, [
            .notBackedUp(path: "b.pem", reason: .renamedFileExcluded),
            .notBackedUp(path: ".ssh", reason: .renamedFolderExcluded),
        ])
        XCTAssertEqual(result.cursors, cursors(120, 120))
    }

    /// 再送される種類（作成時の除外）は同じアイテムを 1 回だけ。呼び出しをまたいでも同じ。
    func testResentKindsAreNotifiedOnce() {
        var notified: Set<String> = []
        let first = FPEventNoticeWatcher.notices(
            in: [
                record(1, details: "a/b\\c.txt", notice: .unsyncableName),
                record(2, details: "a/b\\c.txt", notice: .unsyncableName),
                record(3, path: "link", notice: .symbolicLink),
            ],
            after: cursors(0, 0), notified: &notified)
        XCTAssertEqual(first.events, [
            .notBackedUp(path: "a/b\\c.txt", reason: .unsyncableName),
            .notBackedUp(path: "link", reason: .symbolicLink),
        ])
        let resent = FPEventNoticeWatcher.notices(
            in: [record(4, details: "a/b\\c.txt", notice: .unsyncableName),
                 record(5, path: "link", notice: .symbolicLink)],
            after: first.cursors, notified: &notified)
        XCTAssertTrue(resent.events.isEmpty)
        XCTAssertEqual(resent.cursors, cursors(5, 5))
    }

    /// 「通知済み」の記録は上限に達したら空にする（その後の再送はもう一度知らせる）。
    func testNotifiedKeysAreClearedAtCap() {
        var notified: Set<String> = []
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(1, path: "l1", notice: .symbolicLink),
                record(2, path: "l2", notice: .symbolicLink),
                record(3, path: "l1", notice: .symbolicLink),
            ],
            after: cursors(0, 0), notified: &notified, maxNotifiedKeys: 2)
        XCTAssertEqual(result.events.count, 3, "上限で空にした後の l1 はもう一度知らせる")
        XCTAssertEqual(notified, ["symbolicLink:l1"])
    }

    /// 改名の除外は再送されないので、同じ名前でも毎回知らせる。名前は details（新しい名前）。
    func testRenameKindsAreNotifiedEveryTime() {
        var notified: Set<String> = []
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(1, path: "a.txt", details: "a.env", notice: .renamedFileExcluded),
                record(2, path: "a.txt", details: "a.env", notice: .renamedFileExcluded),
                record(3, path: "keys", details: ".ssh", notice: .renamedFolderExcluded),
            ],
            after: cursors(0, 0), notified: &notified)
        XCTAssertEqual(result.events, [
            .notBackedUp(path: "a.env", reason: .renamedFileExcluded),
            .notBackedUp(path: "a.env", reason: .renamedFileExcluded),
            .notBackedUp(path: ".ssh", reason: .renamedFolderExcluded),
        ])
    }

    /// 名前が取れない印つきレコード（壊れた行）は通知しない。カーソルは進める。
    func testNoticeWithoutSubjectIsSkipped() {
        var notified: Set<String> = []
        let result = FPEventNoticeWatcher.notices(
            in: [record(1, path: nil, details: nil, notice: .unsyncableName),
                 record(2, path: "", notice: .symbolicLink)],
            after: cursors(0, 0), notified: &notified)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursors, cursors(2, 2))
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
            savedRenamedCursor: 40,
            readNew: { log.readNew($0) },
            saveRenamedCursor: { saved.append($0) },
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

    /// 保存が無いとき（初回・factoryReset 後）は、改名も起動時刻から始める。
    func testRenamedCursorStartsAtLaunchWithoutSavedValue() async {
        let log = FakeLog()
        log.pending = [record(50, path: "y.txt", details: "y.pem", notice: .renamedFileExcluded)]
        var posted: [NotificationEvent] = []
        let watcher = FPEventNoticeWatcher(
            startedAt: Date(timeIntervalSince1970: 100),
            savedRenamedCursor: nil,
            readNew: { log.readNew($0) },
            saveRenamedCursor: { _ in },
            post: { posted.append($0) })
        await watcher.checkOnce()
        XCTAssertTrue(posted.isEmpty)
    }
}
