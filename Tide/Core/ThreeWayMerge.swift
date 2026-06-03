import Foundation

/// 双方向同期の競合解決を、ベース / ローカル / リモートの 3 つの SHA から決める純粋ロジック。
///
/// `docs/04-SYNC-LOGIC.md`「競合解決」の表を形式化したもの。判定ロジックを副作用から切り離し、
/// `SyncEngine.reconcileRemoteEntry`（pull 側）と `Downloader.applyRemoteDeletion`（削除側）の
/// 両方がこの単一の関数を通すことで、競合解決の真実をひとつにしユニットテストで全分岐を固める
/// （`IgnoreDecision` / `PartPlan` / `ConflictNamer` と同じ「純粋 enum + static + 全分岐テスト」パターン）。
///
/// ベースは「最後にローカル DB へ記録した SHA」(`FileRecord.sha256`)。マニフェスト schema は拡張しない。
enum MergeDecision: Equatable, Sendable {
    /// リモートを採用（ローカル欠落、またはローカル未編集でリモートのみ変化 → 上書き取得）。
    case download
    /// ローカルとリモートの内容が一致 → 書き込みは不要で DB メタデータのみ更新。
    case localMatchesRemote
    /// 双方が乖離（ローカルも編集 / 未追跡 かつ リモートも別内容）→ ローカルをコンフリクトコピーへ退避してから取得。
    case conflictThenDownload
    /// リモート削除 & ローカルがベースから未編集 → ローカル削除（リモート削除の反映）。
    case deleteLocal
    /// リモート削除だがローカルは編集済み / 未追跡 → 温存し warning（ユーザが触っているとみなす）。
    case keepLocalRemoteDeleted
    /// 何もしない（双方不在など）。
    case noop
}

enum ThreeWayMerge {
    /// 3-way の決定。
    /// - Parameters:
    ///   - base: 最後にローカル DB へ記録した SHA（`FileRecord.sha256`）。未追跡（DB 記録なし）は `nil`。
    ///   - local: 現在のローカルファイルの SHA。ファイル不在は `nil`。
    ///   - remote: リモートマニフェストの SHA。リモートに存在しない（削除済み含む）は `nil`。
    static func decide(base: String?, local: String?, remote: String?) -> MergeDecision {
        switch (local, remote) {
        case (nil, nil):
            // どちらにも無い。
            return .noop
        case (nil, _?):
            // ローカル欠落 / リモートあり → 取得（再作成含む）。
            return .download
        case (_?, nil):
            // リモート削除。ベースから未編集なら削除、そうでなければ温存。
            if let base, base == local { return .deleteLocal }
            return .keepLocalRemoteDeleted
        case let (l?, r?):
            if l == r {
                // 内容一致（「両方が同方向に変化」= l == r != base の fast-forward もここ）。
                return .localMatchesRemote
            }
            if let base, base == l {
                // ローカルは前回同期後に未編集・リモートが変化 → 上書き取得。
                return .download
            }
            // ローカルも編集済み（base != local）or 未追跡（base == nil）→ 双方乖離 → コンフリクト。
            return .conflictThenDownload
        }
    }
}
