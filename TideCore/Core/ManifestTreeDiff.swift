import Foundation

/// 2 つの `ManifestTree` の差分（M5 Phase 4・増分列挙）。
/// `enumerateChanges(from:)` が「システムが最後に見た世代 → 現在」の変化を
/// `didUpdate` / `didDeleteItems` へ写像するための純粋計算。
///
/// - ファイル: entry の変化（sha/size/mtime/versionId 等）・新規出現を `updated` に含める。
/// - ディレクトリ: 出現、および合成 mtime の変化（配下ファイル更新で前進する）を `updated` に
///   含める。
/// - **種別変化（file⇄directory⇄package・同一 path）は「旧ノードの delete + 新ノードの update」に
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
                // パッケージ（#140）も別の種類 = 別 id（`k:`）なので、ファイル ⇄ パッケージ ⇄
                // ディレクトリの変化はすべてここを通る。
                if oldNode.kind != node.kind {
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

    /// 削除に、システムが別の種類で持っているかもしれない id を足す（Issue #163）。
    ///
    /// ツリーの種類は今の台帳（`PackageKindOverrides`）で決まるが、削除・改名でパスの記録を消したあとは、
    /// 起点の世代のそのパスが名前で判定され、システムが持っている種類と違う姿になる。`.xcodeproj` の `d:` の
    /// 改名なら削除は `k:<旧パス>` の 1 件だけになり、配下の `d:` / `f:` の旧 id が届かない。逆向き
    /// （`.framework` の `k:`）は `d:` / `f:` が出て `k:` が届かない。そこで両方の姿の id を削除に載せる。
    /// 未知の id の削除は何も起こさない（2026-11-05 実機）。起点の世代のときの台帳を持たなくて済む。
    ///
    /// 目標のツリーにある id は載せない（生きている item を消さない）。
    public static func includingOtherKinds(_ changes: Changes, target: ManifestTree) -> Changes {
        var seen = Set(changes.deleted.map { Key(path: $0.path, kind: $0.kind) })
        var deleted = changes.deleted
        func add(_ node: ManifestTree.Node) {
            guard target.node(at: node.path)?.kind != node.kind,
                  seen.insert(Key(path: node.path, kind: node.kind)).inserted
            else { return }
            deleted.append(node)
        }
        func addDirectoryLike(_ path: String) {
            add(.directory(path: path, mtime: nil))
            add(ManifestTree.packageNode(path: path, members: [:]))
        }
        for node in changes.deleted {
            switch node {
            case .file:
                break
            case .directory(let path, _):
                add(ManifestTree.packageNode(path: path, members: [:]))
            case .package(let path, let members, _, _):
                addDirectoryLike(path)
                for (relative, entry) in members {
                    var dir = path
                    for component in relative.split(separator: "/").dropLast() {
                        dir += "/\(component)"
                        addDirectoryLike(dir)
                    }
                    add(.file(path: path + "/" + relative, entry: entry))
                }
            }
        }
        deleted.sort { ($0.path, $0.kind.sortOrder) < ($1.path, $1.kind.sortOrder) }
        return Changes(updated: changes.updated, deleted: deleted)
    }

    private struct Key: Hashable {
        let path: String
        let kind: ManifestTree.Node.Kind
    }
}

private extension ManifestTree.Node.Kind {
    /// 削除の並びを決定的にする（同じパスに複数の種類が並ぶ）。
    var sortOrder: Int {
        switch self {
        case .file: return 0
        case .directory: return 1
        case .package: return 2
        }
    }
}
