import TideCore
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
    /// fpOnly: FP ドメインが無効（システム設定 OFF / 未登録）= 全同期停止（Issue #82）。
    case fpDomainDisabled
    /// fpOnly: 直近のリモート確認（index HEAD）が失敗中（一過性か持続かは時刻と併読）。
    case fpRemoteCheckFailed

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

    /// fpOnly（engine 無し・`RemoteChangeSignaler` 稼働）のメニューバー表示（B-2 受け入れで
    /// 発見した B-1 縮退の取りこぼし: engine nil を `.notConfigured` に落とすと fpOnly が
    /// 恒久「？＋波」になる）。増分取り込みの実体は FP 拡張側にあり進行状態は見えないため、
    /// 「正常 = 通常の波 / 異常 = 荒れた海」に落とす。異常は専用 case で区別する
    /// （旧 `.error(summary: "")` 空文字センチネルは廃止 = PR #78 記録 (b) の構造的解消）:
    /// - FP ドメイン無効 = 全同期停止（Issue #82）。一過性の確認失敗より常に優先。
    /// - リモート確認失敗 = 一過性の可能性あり（HEAD 到達性のみの観測）。
    static func fpOnlyHeadline(lastCheckFailed: Bool, fpDomainDisabled: Bool) -> MenuBarPresentation {
        if fpDomainDisabled { return .fpDomainDisabled }
        return lastCheckFailed ? .fpRemoteCheckFailed : .allSynced
    }

    // MARK: - メニューバー status item アイコン

    /// 非 syncing 時の「固定グリフ」アセット名（各 1:1 で imageset が実在する）。
    /// グリフはモノクロのテンプレート画像なのでダーク/ライトにシステム追従する。
    /// `.syncing` は到達しない防御的デフォルト（View 側が下の frame アニメに差し替える）。
    /// 全分岐とアセット実在を `MenuBarPresentationTests` で固定する。
    var menuBarIconName: String {
        switch self {
        case .allSynced:     return "MenuBarWave"          // 月＋ゆるい波
        case .paused:        return "MenuBarPaused"        // 月＋凪（フラットな水面）
        case .error:         return "MenuBarError"         // 月＋荒れた海
        case .notConfigured: return "MenuBarNotConfigured" // ？＋波
        case .syncing:       return "MenuBarWave"          // 実際は frame アニメに差し替わる
        case .fpDomainDisabled:    return "MenuBarError"   // 全同期停止 = エラー系（Issue #82）
        case .fpRemoteCheckFailed: return "MenuBarError"   // 旧 .error(summary: "") と同表示
        }
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    /// syncing 中のコマ送りアニメのフレーム数。`MenuBarSync0…(syncFrameCount-1)` の
    /// imageset と 1:1。`syncFrameName(_:)` が文字列でアセットを引くため、増やすときは
    /// imageset の追加が必須（忘れると無言で空画像になる）＝`MenuBarPresentationTests`
    /// がアセット実在を担保する。
    static let syncFrameCount = 8

    /// アニメ frame 番号 → imageset 名。View と test が同じ生成規則を共有する（単一管理）。
    static func syncFrameName(_ frame: Int) -> String {
        "MenuBarSync\(frame)"
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
