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
        ]
        XCTAssertEqual(Set(ids).count, 4)
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
}
