import XCTest
import TideCore
@testable import Tide

/// `FPEventNoticeWatcher`（Issue #147・FP 拡張イベントの新着 → OS 通知）の単体テスト。
/// 新着の取り出し（カーソル・印・再送される種類の重複除去）と、stat 署名のゲートを固定する。
@MainActor
final class FPEventNoticeWatcherTests: XCTestCase {

    private func record(
        _ timestamp: Double, path: String? = nil, details: String? = nil, notice: FPEventNotice? = nil
    ) -> FPEventRecord {
        FPEventRecord(
            timestamp: timestamp, bucket: "b", eventType: "info", path: path, message: "m",
            details: details, notice: notice?.rawValue)
    }

    // MARK: - notices(in:after:notified:)

    /// カーソル以前のイベントは通知せず、カーソルは印の無いものを含めて最新まで進む。
    func testOnlyRecordsAfterCursorAndCursorAdvances() {
        var notified: Set<String> = []
        let result = FPEventNoticeWatcher.notices(
            in: [
                record(1, path: "old-link", notice: .symbolicLink),
                record(5, path: "new-link", notice: .symbolicLink),
                record(7, path: "plain.txt"),
            ],
            after: 2, notified: &notified)
        XCTAssertEqual(result.events, [.notBackedUp(path: "new-link", reason: .symbolicLink)])
        XCTAssertEqual(result.cursor, 7)
    }

    /// 新着が無ければカーソルは動かない。
    func testCursorUnchangedWithoutNewRecords() {
        var notified: Set<String> = []
        let result = FPEventNoticeWatcher.notices(
            in: [record(1, path: "a", notice: .symbolicLink)], after: 3, notified: &notified)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursor, 3)
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
            after: 0, notified: &notified)
        XCTAssertEqual(first.events, [
            .notBackedUp(path: "a/b\\c.txt", reason: .unsyncableName),
            .notBackedUp(path: "link", reason: .symbolicLink),
        ])
        let resent = FPEventNoticeWatcher.notices(
            in: [record(4, details: "a/b\\c.txt", notice: .unsyncableName),
                 record(5, path: "link", notice: .symbolicLink)],
            after: first.cursor, notified: &notified)
        XCTAssertTrue(resent.events.isEmpty)
        XCTAssertEqual(resent.cursor, 5)
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
            after: 0, notified: &notified)
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
            after: 0, notified: &notified)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursor, 2)
    }

    // MARK: - checkOnce（署名のゲートと起動時刻）

    /// 起動時刻より前のイベントは通知しない。署名が変わらなければログを読まない。
    func testCheckOnceGatesOnSignatureAndStartTime() async {
        final class Box: @unchecked Sendable {
            var records: [FPEventRecord] = []
            var signature = "s0"
            var loads = 0
        }
        let box = Box()
        var posted: [NotificationEvent] = []
        let watcher = FPEventNoticeWatcher(
            startedAt: Date(timeIntervalSince1970: 100),
            loadRecords: { box.loads += 1; return box.records },
            changeSignature: { box.signature },
            post: { posted.append($0) })

        box.records = [record(50, path: "before-launch", notice: .symbolicLink)]
        await watcher.checkOnce()
        XCTAssertTrue(posted.isEmpty, "起動前のイベントは通知しない")
        XCTAssertEqual(box.loads, 1)

        box.records.append(record(150, path: "after-launch", notice: .symbolicLink))
        await watcher.checkOnce()
        XCTAssertEqual(box.loads, 1, "署名が変わらなければ読まない")
        XCTAssertTrue(posted.isEmpty)

        box.signature = "s1"
        await watcher.checkOnce()
        XCTAssertEqual(box.loads, 2)
        XCTAssertEqual(posted, [.notBackedUp(path: "after-launch", reason: .symbolicLink)])

        box.signature = "s2"
        await watcher.checkOnce()
        XCTAssertEqual(posted.count, 1, "同じイベントを二度通知しない")
    }
}
