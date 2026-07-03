import Foundation

/// 有界並列の TaskGroup 実行ヘルパ。
///
/// `ManifestReader` / `ManifestSnapshotLoader` に同型で重複していた「上限付き並列取得」骨格を
/// 一元化する（PR #50 レビュー #7）。この骨格には「上限到達時に消費する `group.next()` の結果を
/// `_ =` で捨てると、アイテム数 > 上限のとき完了分が**エラーなしで**失われる」という再発コストの
/// 高い罠があり、実際に両呼び出し元へ同じバグが複製されていた（実機でファイル欠落として顕在化）。
/// 以後、上限付き並列が要る箇所はこのヘルパを使うこと。
public enum BoundedParallel {
    /// `ids` を最大 `limit` 並列で `transform` し、非 nil の結果を集めて返す。
    /// 結果の順序は完了順（呼び出し元が順序に依存しないこと）。`transform` の throw は伝播する。
    public static func compactMap<ID: Sendable, R: Sendable>(
        _ ids: [ID],
        limit: Int = 8,
        transform: @escaping @Sendable (ID) async throws -> R?
    ) async throws -> [R] {
        try await withThrowingTaskGroup(of: R?.self) { group in
            var acc: [R] = []
            var inflight = 0
            for id in ids {
                if inflight >= limit {
                    // ここで消費する完了結果も必ず回収する（捨てない）
                    if let finished = try await group.next(), let value = finished {
                        acc.append(value)
                    }
                    inflight -= 1
                }
                group.addTask { try await transform(id) }
                inflight += 1
            }
            for try await value in group {
                if let value { acc.append(value) }
            }
            return acc
        }
    }
}
