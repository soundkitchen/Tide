import XCTest
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
}
