import Foundation

/// 2 つの `ManifestTree` の差分（M5 Phase 4・増分列挙）。
/// `enumerateChanges(from:)` が「システムが最後に見た世代 → 現在」の変化を
/// `didUpdate` / `didDeleteItems` へ写像するための純粋計算。
///
/// - ファイル: entry の変化（sha/size/mtime/versionId 等）・新規出現を `updated` に含める。
/// - ディレクトリ: 出現、および合成 mtime の変化（配下ファイル更新で前進する）を `updated` に
///   含める。ファイル→ディレクトリ等の**種別変化も同一 identifier の update** として報告する
///   （システム側が item を差し替える）。
/// - `deletedPaths`: 旧ツリーに在って新ツリーに無いパス（ファイル/ディレクトリ両方）。
/// - ルート（`""`）は対象外（常に存在し、itemVersion も固定）。
/// - 順序は path 昇順（決定的・テスト可能）。
public enum ManifestTreeDiff {
    public struct Changes: Sendable, Equatable {
        /// 変更/出現したノード（path 昇順）。
        public var updated: [ManifestTree.Node]
        /// 消えたパス（path 昇順）。
        public var deletedPaths: [String]

        public var isEmpty: Bool { updated.isEmpty && deletedPaths.isEmpty }

        public init(updated: [ManifestTree.Node], deletedPaths: [String]) {
            self.updated = updated
            self.deletedPaths = deletedPaths
        }
    }

    public static func changes(from old: ManifestTree, to new: ManifestTree) -> Changes {
        var updated: [ManifestTree.Node] = []
        var deleted: [String] = []
        for (path, node) in new.nodesByPath where !path.isEmpty {
            if old.node(at: path) != node {
                updated.append(node)
            }
        }
        for path in old.nodesByPath.keys where !path.isEmpty && new.node(at: path) == nil {
            deleted.append(path)
        }
        updated.sort { $0.path < $1.path }
        deleted.sort()
        return Changes(updated: updated, deletedPaths: deleted)
    }
}
