import Foundation

/// ローカルファイルの変更判定（フルスキャン / FSEvents の共通ロジック）。
/// `IgnoreDecision` / `ThreeWayMerge` と同じく副作用なしの純粋関数に切り出し、
/// `ChangeDetectorTests` で全分岐を固定する。
///
/// docs/04-SYNC-LOGIC.md の仕様（size/mtime 不一致 → SHA 再計算 → ハッシュ一致なら
/// mtime のみ DB 更新・アップロードしない）を実装する two-step 構成:
/// 1. `preDecision`: stat 値だけで「スキップ / enqueue / hash 検証が必要」を判定
/// 2. `postHash`: 計算した SHA と DB 記録の SHA を比較し「mtime 修復のみ / enqueue」を判定
///
/// この SHA ゲートは、mtime だけがドリフトしたファイル（例: マニフェスト秒精度 mtime での
/// DB 汚染・`setAttributes` 失敗）を再アップロードせず自己修復するための安全網。
/// 判定後の副作用（enqueue の `onConflict` の差・`refreshQueueDepth` 等）は呼び元の責務のまま
/// （scan は `.ignore` = リトライ中 attempts を巻き戻さない / event は `.replace` = リセット。
/// 意図的な挙動差なのでここに吸わせない）。
///
/// 将来の第 3 の呼び元: reconcile 入口の stat ゲート（pull が全ツリーを毎回 hash する問題の
/// 最適化・据え置き）もこの API を使う想定。
enum ChangeDetector {
    /// DB（`FileRecord`）由来の既知状態。
    struct Known: Equatable, Sendable {
        var size: Int64
        var mtime: Double
        var sha256: String
        /// `FileRecord.lastSyncedAt != nil`（同期完了済みか）。
        var isSynced: Bool
    }

    enum PreDecision: Equatable, Sendable {
        /// size / mtime とも一致 → 変更なし（hash も不要）。
        case skip
        /// 確実に要アップロード（未知 / 未同期 / size 不一致）。hash 検証は不要。
        case enqueue
        /// size 一致 + mtime 不一致 → 内容が変わったか mtime ドリフトかを SHA で判定する。
        case verifyHash
    }

    /// stat 値だけでの一次判定。
    /// - size 不一致は hash せず `enqueue`: size が違えば sha は一致し得ない（仕様と同義の最適化）。
    /// - tolerance は既存の比較（`abs(diff) < 0.001`）と同値。
    static func preDecision(
        known: Known?,
        size: Int64,
        mtime: Double,
        tolerance: Double = 0.001
    ) -> PreDecision {
        guard let known, known.isSynced else { return .enqueue }
        guard known.size == size else { return .enqueue }
        if abs(known.mtime - mtime) < tolerance { return .skip }
        return .verifyHash
    }

    enum PostHashDecision: Equatable, Sendable {
        /// 内容は不変＝mtime ドリフトのみ → DB の mtime を現 stat 値へ修復し、アップロードしない。
        case refreshMtimeOnly
        /// 内容が変わった（or hash 不能）→ アップロードキューへ。
        case enqueue
    }

    /// `verifyHash` 後の二次判定。`computedSha == nil`（hash 失敗）は enqueue に倒す
    /// （従来も mtime 不一致なら無条件 enqueue → Uploader 側が open 失敗を delete 変換 /
    /// symlink skip するため、失敗時挙動は従来と同一）。
    static func postHash(knownSha: String, computedSha: String?) -> PostHashDecision {
        guard let computedSha, computedSha == knownSha else { return .enqueue }
        return .refreshMtimeOnly
    }
}
