import AppKit
import XCTest
import TideCore
@testable import Tide

final class MenuBarPresentationTests: XCTestCase {
    // MARK: - headline

    func testNotConfiguredPausedErrorPassThrough() {
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .notConfigured, queueDepth: 0, activeTransferCount: 0),
            .notConfigured
        )
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .paused, queueDepth: 3, activeTransferCount: 1),
            .paused
        )
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .error("Network error"), queueDepth: 0, activeTransferCount: 0),
            .error(summary: "Network error")
        )
    }

    func testSyncingStatusReportsPending() {
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .syncing(SyncProgress()), queueDepth: 4, activeTransferCount: 2),
            .syncing(pending: 4)
        )
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .syncing(SyncProgress()), queueDepth: 0, activeTransferCount: 0),
            .syncing(pending: 0)
        )
    }

    /// .idle でも queue / 転送が残っていれば「同期済み」と誤表示しない（処理周回の谷間）。
    func testIdleWithPendingWorkIsSyncing() {
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .idle, queueDepth: 2, activeTransferCount: 0),
            .syncing(pending: 2)
        )
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .idle, queueDepth: 0, activeTransferCount: 1),
            .syncing(pending: 1)
        )
    }

    /// allSynced は .idle かつ queue 0 かつ転送 0 のときだけ。
    func testAllSyncedOnlyWhenIdleAndEmpty() {
        XCTAssertEqual(
            MenuBarPresentation.headline(status: .idle, queueDepth: 0, activeTransferCount: 0),
            .allSynced
        )
    }

    // MARK: - groupIssues

    private func issue(
        _ category: SyncIssue.Category, path: String? = nil, at seconds: Double
    ) -> SyncIssue {
        SyncIssue(
            id: UUID(),
            date: Date(timeIntervalSince1970: seconds),
            path: path,
            category: category,
            rawDetail: "raw"
        )
    }

    func testGroupIssuesEmptyInput() {
        XCTAssertTrue(MenuBarPresentation.groupIssues([]).isEmpty)
    }

    /// グループは「最新 issue を含むものが先」、グループ内は新しい順。
    func testGroupIssuesOrdersByRecency() {
        // recentIssues と同じく古い順に積む: network(1), fileTooLarge(2), network(3)
        let issues = [
            issue(.network, path: "a.txt", at: 1),
            issue(.fileTooLarge, path: "big.zip", at: 2),
            issue(.network, path: "b.txt", at: 3),
        ]
        let groups = MenuBarPresentation.groupIssues(issues)

        XCTAssertEqual(groups.map(\.category), [.network, .fileTooLarge], "最新（network@3）のグループが先")
        XCTAssertEqual(groups[0].issues.map(\.path), ["b.txt", "a.txt"], "グループ内は新しい順")
        XCTAssertEqual(groups[1].issues.map(\.path), ["big.zip"])
    }

    func testGroupIssuesCountsAllOccurrences() {
        let issues = [
            issue(.network, at: 1),
            issue(.network, at: 2),
            issue(.network, at: 3),
        ]
        let groups = MenuBarPresentation.groupIssues(issues)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].issues.count, 3)
    }

    // MARK: - メニューバー status item アイコン

    /// 固定グリフのマッピングを全分岐固定（到達しない `.syncing` 既定値も含む）。
    func testMenuBarIconNameForEachCase() {
        XCTAssertEqual(MenuBarPresentation.notConfigured.menuBarIconName, "MenuBarNotConfigured")
        XCTAssertEqual(MenuBarPresentation.allSynced.menuBarIconName, "MenuBarWave")
        XCTAssertEqual(MenuBarPresentation.paused.menuBarIconName, "MenuBarPaused")
        XCTAssertEqual(MenuBarPresentation.error(summary: "x").menuBarIconName, "MenuBarError")
        XCTAssertEqual(MenuBarPresentation.syncing(pending: 1).menuBarIconName, "MenuBarWave")
    }

    /// `isSyncing` は `.syncing` のときだけ true。
    func testIsSyncingFlag() {
        XCTAssertTrue(MenuBarPresentation.syncing(pending: 0).isSyncing)
        let nonSyncing: [MenuBarPresentation] = [.notConfigured, .allSynced, .paused, .error(summary: "x")]
        for p in nonSyncing {
            XCTAssertFalse(p.isSyncing, "\(p) は syncing でない")
        }
    }

    /// fpOnly（engine 無し・signaler 稼働）のマッピングを固定（B-2 実機受け入れで発見した
    /// B-1 縮退取りこぼし: engine nil → .notConfigured で恒久「？＋波」になる回帰の防止）。
    func testFPOnlyHeadline() {
        XCTAssertEqual(MenuBarPresentation.fpOnlyHeadline(lastCheckFailed: false), .allSynced)
        XCTAssertEqual(
            MenuBarPresentation.fpOnlyHeadline(lastCheckFailed: true), .error(summary: "")
        )
        // アイコンは「通常の波 / 荒れた海」の 2 値（? グリフに落ちない）。
        XCTAssertEqual(
            MenuBarPresentation.fpOnlyHeadline(lastCheckFailed: false).menuBarIconName, "MenuBarWave"
        )
        XCTAssertEqual(
            MenuBarPresentation.fpOnlyHeadline(lastCheckFailed: true).menuBarIconName, "MenuBarError"
        )
    }

    /// frame 番号 → アセット名の生成規則を固定（View と共有する単一の規則）。
    func testSyncFrameNameFormat() {
        XCTAssertEqual(MenuBarPresentation.syncFrameName(0), "MenuBarSync0")
        XCTAssertEqual(MenuBarPresentation.syncFrameName(7), "MenuBarSync7")
    }

    /// status item に出す全アセットが実在することを担保する（文字列ベース参照が
    /// アセット追加漏れで「無言の空画像」になる事故を防ぐ）。テストホストが Tide.app なので
    /// `NSImage(named:)` は本番表示と同じ main bundle の asset catalog を引く。
    func testMenuBarIconAssetsExist() {
        let glyphs: [MenuBarPresentation] = [.notConfigured, .allSynced, .paused, .error(summary: "x")]
        for p in glyphs {
            XCTAssertNotNil(NSImage(named: p.menuBarIconName), "固定グリフのアセット欠落: \(p.menuBarIconName)")
        }
        for frame in 0..<MenuBarPresentation.syncFrameCount {
            let name = MenuBarPresentation.syncFrameName(frame)
            XCTAssertNotNil(NSImage(named: name), "syncing フレームのアセット欠落: \(name)")
        }
    }
}
