import Foundation

/// ローカルファイルの状態。`decide()` が「不在」と「存在するが SHA を計算できない（unreadable）」を
/// 区別できるようにするための型。
///
/// 旧実装ではこの 2 つが両方 `nil` に畳まれ、同じ物理状態（在るが読めない）が pull 側＝無確認上書き /
/// 削除側＝温存、と非対称な結末になっていた（PR #3 レビュー指摘 1）。`LocalState` で意味論を `decide()` に
/// 集約し、**pull 側の unreadable も「無確認上書き」ではなく保守的にコンフリクトコピー退避へ倒す**（データ安全側）。
enum LocalState: Equatable, Sendable {
    case absent              // ファイルが無い
    case unreadable          // ファイルはあるが SHA を計算できない（権限 / I/O エラー等）
    case present(String)     // SHA が取れた（hex 小文字）
}

/// 双方向同期の競合解決を、ベース / ローカル / リモートの SHA から決める純粋ロジック。
///
/// `docs/04-SYNC-LOGIC.md`「競合解決」の表を形式化したもの。判定ロジックを副作用から切り離し、
/// `SyncEngine.reconcileRemoteEntry`（pull 側）と `Downloader.applyRemoteDeletion`（削除側）の
/// 両方がこの単一の関数を通すことで、競合解決の真実をひとつにしユニットテストで全分岐を固める
/// （`IgnoreDecision` / `PartPlan` / `ConflictNamer` と同じ「純粋 enum + static + 全分岐テスト」パターン）。
///
/// ベースは「最後にローカル DB へ記録した SHA」(`FileRecord.sha256`)。マニフェスト schema は拡張しない。
///
/// `.localMatchesRemote` と `.download` は pull 側の呼び出しでは同一の `Downloader.download()` に畳まれる
/// （`download()` は内容一致時に早期 return で書き込みをせず DB メタデータだけ更新する）。enum で分けているのは
/// 「内容一致による fast-forward」と「リモート採用の上書き」を**意味的に区別してテスト/ドキュメントしやすくする**ため。
enum MergeDecision: Equatable, Sendable {
    /// リモートを採用（ローカル欠落、またはローカル未編集でリモートのみ変化 → 上書き取得）。
    case download
    /// ローカルとリモートの内容が一致 → 書き込みは不要で DB メタデータのみ更新。
    case localMatchesRemote
    /// 双方が乖離（ローカルも編集 / 未追跡 / unreadable かつ リモートも別内容）→ ローカルをコンフリクトコピーへ退避してから取得。
    case conflictThenDownload
    /// リモート削除 & ローカルがベースから未編集 → ローカル削除（リモート削除の反映）。
    case deleteLocal
    /// リモート削除だがローカルは編集済み / 未追跡 / unreadable → 温存し warning（ユーザが触っているとみなす）。
    case keepLocalRemoteDeleted
    /// 何もしない（双方不在など）。
    case noop
}

enum ThreeWayMerge {
    /// 3-way の決定。
    /// - Parameters:
    ///   - base: 最後にローカル DB へ記録した SHA（`FileRecord.sha256`）。未追跡（DB 記録なし）は `nil`。
    ///   - local: 現在のローカルファイルの状態（`.absent` / `.unreadable` / `.present(sha)`）。
    ///   - remote: リモートマニフェストの SHA。リモートに存在しない（削除済み含む）は `nil`。
    static func decide(base: String?, local: LocalState, remote: String?) -> MergeDecision {
        switch (local, remote) {
        case (.absent, nil):
            // どちらにも無い。
            return .noop
        case (.absent, _?):
            // ローカル欠落 / リモートあり → 取得（再作成含む）。
            return .download
        case (.unreadable, nil):
            // 削除側: 存在するが読めない → 未編集と確認できないので温存（保守的）。
            return .keepLocalRemoteDeleted
        case (.unreadable, _?):
            // pull 側: 読めない＝乖離の有無を確認できない → 無確認で上書きせず、コンフリクトコピーで退避してから取得。
            return .conflictThenDownload
        case let (.present(l), nil):
            // リモート削除。ベースから未編集なら削除、そうでなければ温存。
            if let base, base == l { return .deleteLocal }
            return .keepLocalRemoteDeleted
        case let (.present(l), r?):
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
