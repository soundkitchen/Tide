import Foundation

/// マニフェスト条件付き更新（ETag CAS）のリトライポリシー（Issue #91）。
///
/// バースト書込では index.json（単一オブジェクト）への CAS が全書込の競合点になり、
/// 旧実装（100–500ms 一様ランダム × 5 回固定・shard/index 共用）は 100 件規模の一斉書込で
/// 枯渇した（#83 実機受け入れで実測: 作成 20 件 + 削除 44 件が枯渇）。指数バックオフ +
/// ±25% ジッタへ変更し、shard 用 / index 用を別ポリシーとして分離する。
///
/// 実運用値は `.shard` / `.index`。テストは遅延ゼロのポリシーを注入して枯渇分岐を高速に
/// 回帰固定する（`ManifestUpdaterTests`）。
public struct ConditionalRetryPolicy: Sendable {
    /// 総試行回数（初回を含む）。
    public var attempts: Int
    /// 初回リトライ前の基準遅延（ns）。リトライごとに 2 倍へ逓増する。
    public var baseDelayNanos: UInt64
    /// 逓増遅延の上限（ns）。ジッタ適用前の値に対して刈る。
    public var maxDelayNanos: UInt64

    public init(attempts: Int, baseDelayNanos: UInt64, maxDelayNanos: UInt64) {
        self.attempts = attempts
        self.baseDelayNanos = baseDelayNanos
        self.maxDelayNanos = maxDelayNanos
    }

    /// シャード用: 5 回・100ms 起点 ×2 逓増・上限 1.6s（合計最悪 ≈ 1.9s）。
    /// シャードは 256 分散で競合が薄く、回数は旧実装と同じ 5 回を維持。
    /// deleteItem「数秒以内」のシステム契約（docs/08 5-3 節）の範囲に収める。
    public static let shard = ConditionalRetryPolicy(
        attempts: 5, baseDelayNanos: 100_000_000, maxDelayNanos: 1_600_000_000
    )

    /// index.json 用: 8 回・100ms 起点 ×2 逓増・上限 2s。単一オブジェクトの競合点のため
    /// shard より厚い（プロセス内はコアレスで畳むので、ここで受けるのはプロセス間 /
    /// デバイス間の残余競合）。
    public static let index = ConditionalRetryPolicy(
        attempts: 8, baseDelayNanos: 100_000_000, maxDelayNanos: 2_000_000_000
    )

    /// attempt（0 始まり）に対応する遅延。指数逓増を上限で刈り、±25% ジッタを掛ける
    /// （同時に枯れ始めた書き手が同位相で再衝突し続けるのを崩す）。
    public func delayNanos(forAttempt attempt: Int) -> UInt64 {
        guard baseDelayNanos > 0, maxDelayNanos > 0 else { return 0 }
        let shift = min(max(attempt, 0), 16)
        let (exponential, overflow) = baseDelayNanos.multipliedReportingOverflow(by: UInt64(1) << shift)
        let capped = overflow ? maxDelayNanos : min(exponential, maxDelayNanos)
        let lower = capped - capped / 4
        let upper = capped + capped / 4
        return UInt64.random(in: lower...max(lower, upper))
    }
}

/// シャード / index.json の楽観的ロック更新を共通化したリトライ実行
/// （`ManifestUpdater` と `IndexUpdateCoalescer` が共用）。
/// 412 PreconditionFailed / 409 ConditionalRequestConflict（同一オブジェクトへの並行更新に
/// よる一時的失敗）のみ、ポリシーに従うバックオフで再試行する。それ以外は即時伝播。
enum ConditionalRetry {
    /// - 自前の `SyncError` は素通しする（PR #56 レビュー ①）: クラシファイアは
    ///   `String(describing:)` の部分文字列マッチなので、下位エラー文字列を埋め込む
    ///   `manifestUpdateFailed` や path を含む `uploadConflict`（"file-412.txt" 等）が
    ///   「リトライ可能な 412」に誤分類されると、外側再実行が「index 未更新のまま静かな成功」に
    ///   化ける（恒久 stale の温床）。
    /// `isolation` は呼び出し元の isolation を継承する（`#isolation`）: actor 内
    /// （`IndexUpdateCoalescer.flush`）から非 Sendable な operation を渡しても isolation を
    /// 跨がず、strict concurrency 下でそのまま実行できる。
    static func run<T>(
        _ label: String,
        policy: ConditionalRetryPolicy,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<policy.attempts {
            do {
                return try await operation()
            } catch {
                if error is SyncError { throw error }
                if S3ErrorClassifier.isPreconditionFailed(error)
                    || S3ErrorClassifier.isConditionalConflict(error) {
                    lastError = error
                    try? await Task.sleep(nanoseconds: policy.delayNanos(forAttempt: attempt))
                    continue
                }
                throw error
            }
        }
        throw SyncError.manifestUpdateFailed(
            "\(label) conditional update failed \(policy.attempts) times: \(String(describing: lastError))"
        )
    }
}
