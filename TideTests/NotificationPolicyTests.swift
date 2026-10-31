import XCTest
import TideCore
@testable import Tide

final class NotificationPolicyTests: XCTestCase {
    // MARK: - identifier（言語非依存・dedup の要）

    /// 同一 (path, 種別) は同じ identifier ＝ UNUserNotificationCenter で 1 件に置換される。
    func testIdentifierIsStablePerPathAndKind() {
        XCTAssertEqual(
            NotificationPolicy.content(for: .conflictCopyCreated(path: "a/b.txt", localCopyPath: "a/b (copy).txt")).identifier,
            "conflict:a/b.txt"
        )
        XCTAssertEqual(
            NotificationPolicy.content(for: .fileTooLarge(path: "a/b.txt")).identifier,
            "tooLarge:a/b.txt"
        )
        XCTAssertEqual(
            NotificationPolicy.content(for: .uploadGaveUp(path: "a/b.txt")).identifier,
            "gaveUp:a/b.txt"
        )
        XCTAssertEqual(
            NotificationPolicy.content(for: .fileKeepsChanging(path: "a/b.txt")).identifier,
            "unstable:a/b.txt"
        )
        // FP 拡張 OFF（#103）は path を持たない単一事象 = identifier 固定（再発火も 1 件に置換・
        // 復帰エッジの撤去も同じ識別子で行う load-bearing な契約）。
        XCTAssertEqual(
            NotificationPolicy.content(for: .fileProviderDisabled).identifier,
            "fpDisabled"
        )
    }

    /// 種別が同じでも path が違えば identifier は別（畳まれない）。
    func testIdentifierDiffersByPath() {
        let a = NotificationPolicy.content(for: .fileTooLarge(path: "x.bin")).identifier
        let b = NotificationPolicy.content(for: .fileTooLarge(path: "y.bin")).identifier
        XCTAssertNotEqual(a, b)
    }

    /// path が同じでも種別が違えば identifier は別（同時に別カテゴリの通知を出せる）。
    func testIdentifierDiffersByKind() {
        let path = "shared.dat"
        let ids = [
            NotificationPolicy.content(for: .conflictCopyCreated(path: path, localCopyPath: "c")).identifier,
            NotificationPolicy.content(for: .fileTooLarge(path: path)).identifier,
            NotificationPolicy.content(for: .uploadGaveUp(path: path)).identifier,
            NotificationPolicy.content(for: .fileKeepsChanging(path: path)).identifier,
            NotificationPolicy.content(for: .writeKeepsFailing(path: path)).identifier,
        ]
        XCTAssertEqual(Set(ids).count, 5)
    }

    // MARK: - 表示内容（タイトル / 本文）

    /// すべての種別でタイトル・本文が非空。
    func testTitleAndBodyNonEmpty() {
        let events: [NotificationEvent] = [
            .conflictCopyCreated(path: "p", localCopyPath: "q"),
            .fileTooLarge(path: "p"),
            .uploadGaveUp(path: "p"),
            .fileKeepsChanging(path: "p"),
            .fileProviderDisabled,
            .writeKeepsFailing(path: "p"),
            .writeKeepsFailingMore(count: 2),
        ]
        for e in events {
            let c = NotificationPolicy.content(for: e)
            XCTAssertFalse(c.title.isEmpty, "title empty for \(e)")
            XCTAssertFalse(c.body.isEmpty, "body empty for \(e)")
        }
    }

    /// 本文にはフルパスでなくファイル名（末尾コンポーネント）を出す（通知は幅が狭い）。
    func testBodyUsesFileNameNotFullPath() {
        let c = NotificationPolicy.content(for: .fileTooLarge(path: "deep/nested/report.pdf"))
        XCTAssertTrue(c.body.contains("report.pdf"), "body should mention the file name: \(c.body)")
        XCTAssertFalse(c.body.contains("deep/nested/"), "body should not contain the full path: \(c.body)")
    }

    // MARK: - バックアップされないファイル（Issue #147）

    /// identifier は (種類, 表示パス) ごとに固定。種類かパスが違えば別の通知になる。
    func testNotBackedUpIdentifierPerReasonAndPath() {
        XCTAssertEqual(
            NotificationPolicy.content(for: .notBackedUp(path: "a/b\\c.txt", reason: .unsyncableName)).identifier,
            "notBackedUp:unsyncableName:a/b\\c.txt"
        )
        let ids = FPEventNotice.allCases.map {
            NotificationPolicy.content(for: .notBackedUp(path: "same", reason: $0)).identifier
        }
        XCTAssertEqual(Set(ids).count, FPEventNotice.allCases.count)
        XCTAssertNotEqual(
            NotificationPolicy.content(for: .notBackedUp(path: "x", reason: .symbolicLink)).identifier,
            NotificationPolicy.content(for: .notBackedUp(path: "y", reason: .symbolicLink)).identifier
        )
    }

    /// すべての種類で、本文はファイル名（末尾）を含み、フルパスを含まない。種類ごとに本文が違う。
    func testNotBackedUpBodyNamesTheFile() {
        var bodies: Set<String> = []
        for reason in FPEventNotice.allCases {
            let c = NotificationPolicy.content(for: .notBackedUp(path: "deep/nested/secret.env", reason: reason))
            XCTAssertFalse(c.title.isEmpty)
            XCTAssertTrue(c.body.contains("secret.env"), "body should mention the name: \(c.body)")
            XCTAssertFalse(c.body.contains("deep/nested/"), "body should not contain the full path: \(c.body)")
            bodies.insert(c.body)
        }
        XCTAssertEqual(bodies.count, FPEventNotice.allCases.count)
    }

    /// まとめの通知は identifier 固定（次のまとめで置き換える）で、本文に件数を含む。
    func testNotBackedUpMoreIsFixedIdentifierWithCount() {
        let a = NotificationPolicy.content(for: .notBackedUpMore(count: 7))
        let b = NotificationPolicy.content(for: .notBackedUpMore(count: 12))
        XCTAssertEqual(a.identifier, "notBackedUp:more")
        XCTAssertEqual(a.identifier, b.identifier)
        XCTAssertFalse(a.title.isEmpty)
        XCTAssertTrue(a.body.contains("7"), "body should mention the count: \(a.body)")
    }

    // MARK: - 書込の失敗が続く（Issue #148）

    /// 本文はファイル名と回数を含み、identifier はパスごと。まとめは identifier 固定で件数を含む。
    func testWriteKeepsFailingContent() {
        let c = NotificationPolicy.content(for: .writeKeepsFailing(path: "deep/report.pdf"))
        XCTAssertEqual(c.identifier, "keepsFailing:deep/report.pdf")
        XCTAssertTrue(c.body.contains("report.pdf"), c.body)
        XCTAssertFalse(c.body.contains("deep/"), c.body)
        XCTAssertTrue(c.body.contains("\(FPEventNoticeWatcher.failureThreshold)"), c.body)

        let a = NotificationPolicy.content(for: .writeKeepsFailingMore(count: 7))
        let b = NotificationPolicy.content(for: .writeKeepsFailingMore(count: 9))
        XCTAssertEqual(a.identifier, "keepsFailing:more")
        XCTAssertEqual(a.identifier, b.identifier)
        XCTAssertTrue(a.body.contains("7"), a.body)
    }
}
