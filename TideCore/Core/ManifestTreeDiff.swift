import Foundation

/// 2 つの `ManifestTree` の差分（M5 Phase 4・増分列挙）。
/// `enumerateChanges(from:)` が「システムが最後に見た世代 → 現在」の変化を
/// `didUpdate` / `didDeleteItems` へ写像するための純粋計算。
///
/// - ファイル: entry の変化（sha/size/mtime/versionId 等）・新規出現を `updated` に含める。
/// - ディレクトリ: 出現、および合成 mtime の変化（配下ファイル更新で前進する）を `updated` に
///   含める。
/// - **種別変化（file⇄directory・同一 path）は「旧ノードの delete + 新ノードの update」に
///   分解する**（M5 Phase 5-1）: fileproviderd は同一 id の kind 変化を受理しない（update 単発は
///   itemKindMismatch でゾンビ化、単一レスポンス/moreComing ページ/近接別セッションの
///   delete+update は ingest 合成で delete が勝つ = 2026-07-05〜06 実機確定）。item identifier は
///   kind 織り込み形式（`f:`/`d:` + path）なので、旧 kind ノードの delete と新 kind ノードの
///   update は**別 id** となり、単一セッションで安全に配信できる。
/// - `deleted`: 旧ツリーに在って新ツリーに無いノード + 種別変化した旧 kind ノード
///   （kind 情報ごと返す = 呼び出し側が旧 id を正しく組める）。
/// - ルート（`""`）は対象外（常に存在し、itemVersion も固定）。
/// - 順序は path 昇順（決定的・テスト可能）。
public enum ManifestTreeDiff {
    public struct Changes: Sendable, Equatable {
        /// 変更/出現したノード（path 昇順）。
        public var updated: [ManifestTree.Node]
        /// 消えたノード（旧ツリー側の姿・path 昇順）。種別変化の旧 kind ノードを含む。
        public var deleted: [ManifestTree.Node]

        public var isEmpty: Bool { updated.isEmpty && deleted.isEmpty }

        public init(updated: [ManifestTree.Node], deleted: [ManifestTree.Node]) {
            self.updated = updated
            self.deleted = deleted
        }
    }

    public static func changes(from old: ManifestTree, to new: ManifestTree) -> Changes {
        var updated: [ManifestTree.Node] = []
        var deleted: [ManifestTree.Node] = []
        for (path, node) in new.nodesByPath where !path.isEmpty {
            guard let oldNode = old.node(at: path) else {
                updated.append(node)
                continue
            }
            if oldNode != node {
                updated.append(node)
                // 種別変化は旧 kind ノードの delete も併せて出す（M5 Phase 5-1・ヘッダ参照）。
                if oldNode.isDirectory != node.isDirectory {
                    deleted.append(oldNode)
                }
            }
        }
        for (path, node) in old.nodesByPath where !path.isEmpty && new.node(at: path) == nil {
            deleted.append(node)
        }
        updated.sort { $0.path < $1.path }
        deleted.sort { $0.path < $1.path }
        return Changes(updated: updated, deleted: deleted)
    }
}
