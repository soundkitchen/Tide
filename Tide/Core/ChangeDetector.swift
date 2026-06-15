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
/// 第 3 の呼び元: reconcile 入口の stat ゲート（pull が全ツリーを毎回 hash + 全行 DB write する
/// 問題の最適化・M4・2026-06-16）も `preDecision` を使う（下記 `reconcileIsNoop`）。
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

    /// reconcile（pull 取り込み）入口の stat ゲート（第 3 の呼び元）。
    ///
    /// pull は remoteMap の全 entry を `reconcileRemoteEntry` に通すが、未変化シャードの entry は
    /// `ManifestReader` が DB レコードそのものから再合成する（sha/etag/versionId/size/mtime 全部 DB 由来）。
    /// その結果 steady-state では「ローカル == DB == リモート」なのに毎 pull（最短 3 分毎）に全ファイルを
    /// 2 回 hash + 全行 DB write していた。これを消すためのゲート。
    ///
    /// 真なら hash も DB write も不要で reconcile をスキップしてよい。条件:
    /// 1. ローカル stat が DB の (size, mtime) と一致（= `preDecision` の `.skip`）＝ローカル未変更。
    /// 2. DB がリモート entry を**そのまま反映**している（sha / etag / versionId 一致）。
    ///
    /// このとき `markSynced`（= 旧 `updateDBEntryWithoutWrite`）が書く値は、`lastSyncedAt`/`updatedAt`
    /// の timestamp を除いて DB の現値と完全一致する。よってスキップは振る舞い上 **no-op**（証明可能）。
    /// timestamp は再合成マニフェストの `uploadedAt` に使われるだけで、再合成は read 専用＝S3 に戻らず
    /// ロジック上の比較対象にもならないため、bump を省いても無害（むしろ uploadedAt の意味として正しい）。
    ///
    /// クロスデバイスで同一内容が再アップロードされ etag だけ変わった場合はこのゲートが外れ、
    /// 通常経路の hash → `.localMatchesRemote` → `markSynced` で DB の etag/versionId が最新化される。
    static func reconcileIsNoop(
        known: Known?,
        localSize: Int64,
        localMtime: Double,
        knownEtag: String,
        knownVersionId: String?,
        remoteSha: String,
        remoteEtag: String,
        remoteVersionId: String?,
        tolerance: Double = 0.001
    ) -> Bool {
        guard let known else { return false }
        guard preDecision(known: known, size: localSize, mtime: localMtime, tolerance: tolerance) == .skip
        else { return false }
        return known.sha256 == remoteSha
            && knownEtag == remoteEtag
            && knownVersionId == remoteVersionId
    }
}
