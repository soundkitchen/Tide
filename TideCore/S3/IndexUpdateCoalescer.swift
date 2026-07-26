import Foundation

/// index.json 更新のプロセス内コアレッサ（Issue #91）。
///
/// マニフェスト書込 RMW の最終段は全経路が単一オブジェクト index.json への CAS に収束する。
/// per-file deleteItem × 100 のようなバーストではプロセス内の書き手同士が 412 で潰し合い、
/// リトライ枯渇 → 部分完了（孤児オブジェクト + stale index 宣言）に至った（#83 実測・
/// 作成 20 件 + 削除 44 件）。本 actor はプロセス内の index 更新を直列化し、flush の in-flight
/// 中に届いた transform を次の flush へ束ねて「1 回の getIndex → 全 transform 適用 →
/// putIndex(CAS)」に畳む。プロセス内競合は構造的に消え、CAS リトライが受けるのは
/// プロセス間 / デバイス間の残余競合のみになる。
///
/// 意味論の維持（load-bearing）:
/// - 呼び出し側は「自分の transform を含む putIndex の確定」を await してから戻る =
///   `onManifestDidWrite`「shard + index 双方確定時のみ発火」の確定点は不変。
/// - transform が false（CAS 中止）を返した呼び出しには書かずに false を返す（per-caller）。
/// - 412/409 リトライは flush 単位で、再取得した新鮮な index に全 transform を再評価する
///   （従来の per-call リトライと同じ「毎試行、新鮮な index に対して判定」の規約）。
/// - リトライ枯渇はその flush に載った全呼び出しへ `manifestUpdateFailed` として伝播する。
public actor IndexUpdateCoalescer {
    public typealias Transform = @Sendable (inout ManifestIndex) -> Bool

    private let store: any ManifestStore
    private let deviceId: String
    private let policy: ConditionalRetryPolicy
    private var pending: [(transform: Transform, continuation: CheckedContinuation<Bool, any Error>)] = []
    private var isFlushing = false

    /// 待機中（未 flush）の transform 数。テストのバッチ構成制御専用。
    public var pendingCount: Int { pending.count }

    public init(store: any ManifestStore, deviceId: String, policy: ConditionalRetryPolicy) {
        self.store = store
        self.deviceId = deviceId
        self.policy = policy
    }

    /// transform を積み、それが commit（または no-op 確定）されるまで待つ。
    /// - Returns: 自分の transform が実際に index を変更したか。
    public func submit(_ transform: @escaping Transform) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((transform, continuation))
            if !isFlushing {
                isFlushing = true
                Task { await self.drain() }
            }
        }
    }

    /// pending が尽きるまで flush を繰り返す。isFlushing ガードで drain は常に 1 本
    /// （`drain` 内の同期区間では await を跨がないため、末尾の isFlushing = false と
    /// 新規 submit の isFlushing 判定は actor 直列化で競合しない）。
    private func drain() async {
        while !pending.isEmpty {
            let batch = pending
            pending.removeAll()
            do {
                let wrote = try await flush(batch.map(\.transform))
                for (offset, item) in batch.enumerated() {
                    item.continuation.resume(returning: wrote[offset])
                }
            } catch {
                for item in batch {
                    item.continuation.resume(throwing: error)
                }
            }
        }
        isFlushing = false
    }

    /// 1 バッチぶんの index RMW（CAS リトライ込み）。
    private func flush(_ transforms: [Transform]) async throws -> [Bool] {
        try await ConditionalRetry.run("index.json", policy: policy) {
            let fetched = try await store.getIndex()
            var index = fetched?.value ?? ManifestIndex.empty(updatedBy: deviceId)
            var results: [Bool] = []
            results.reserveCapacity(transforms.count)
            var anyChanged = false
            for transform in transforms {
                let changed = transform(&index)
                results.append(changed)
                anyChanged = anyChanged || changed
            }
            guard anyChanged else { return results }
            index.updatedAt = ISO8601.now()
            index.updatedBy = deviceId
            _ = try await store.putIndex(index, ifMatch: fetched?.etag)
            return results
        }
    }
}
