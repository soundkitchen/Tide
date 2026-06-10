import Foundation

/// メニューバーポップオーバーの見出し状態の決定（副作用ゼロの純粋ロジック・
/// `MenuBarPresentationTests` で全分岐固定）。表示文言 / アイコンは View 層が持つ。
enum MenuBarPresentation: Equatable {
    case notConfigured
    case allSynced
    /// pending = 残作業の目安（queueDepth と転送中件数の大きい方）。
    case syncing(pending: Int)
    case paused
    case error(summary: String)

    /// 「すべて同期済み」は **`.idle` かつ queue 0 かつ転送中 0** のときだけ。
    /// `.idle` でも queue > 0 / 転送中 > 0 なら syncing 扱いにする（キュー処理周回の谷間で
    /// status が一瞬 idle に見える状態を「同期済み」と誤表示しない）。
    static func headline(
        status: SyncStatus, queueDepth: Int, activeTransferCount: Int
    ) -> MenuBarPresentation {
        switch status {
        case .notConfigured:
            return .notConfigured
        case .paused:
            return .paused
        case .error(let summary):
            return .error(summary: summary)
        case .syncing:
            return .syncing(pending: max(queueDepth, activeTransferCount))
        case .idle:
            if queueDepth > 0 || activeTransferCount > 0 {
                return .syncing(pending: max(queueDepth, activeTransferCount))
            }
            return .allSynced
        }
    }

    /// recentIssues のカテゴリ別グルーピング（ポップオーバーの issuesCard 用）。
    /// グループは「最新 issue を含むものが先」、グループ内は新しい順。
    struct IssueGroup: Equatable {
        let category: SyncIssue.Category
        let issues: [SyncIssue]
    }

    static func groupIssues(_ issues: [SyncIssue]) -> [IssueGroup] {
        var order: [SyncIssue.Category] = []
        var byCategory: [SyncIssue.Category: [SyncIssue]] = [:]
        // recentIssues は古い順に積まれているので、逆順（新しい順）に走査する。
        for issue in issues.reversed() {
            if byCategory[issue.category] == nil {
                order.append(issue.category)
            }
            byCategory[issue.category, default: []].append(issue)
        }
        return order.map { IssueGroup(category: $0, issues: byCategory[$0] ?? []) }
    }
}
