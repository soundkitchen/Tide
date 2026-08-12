import FileProvider
import Foundation
import TideCore
import UniformTypeIdentifiers

/// `ManifestTree.Node` を `NSFileProviderItem` に写像する読み取り専用アイテム（M5 Phase 3）。
/// identifier = kind プレフィックス + 相対 POSIX パス（`f:`/`d:`・ルートは `.rootContainer`。
/// M5 Phase 5-1 で kind 織り込み形式へ変更）。バージョンは sha256 をそのまま使う。
/// 実体化バッジ（Issue #65）: `materialized` フラグが decorations（チェックバッジ）と
/// metadataVersion の複合符号化（`|m` サフィックス）の両方に反映される。
final class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating,
    @unchecked Sendable
{
    /// Info.plist（`project.yml` の `NSFileProviderDecorations`）で宣言した実体化バッジの
    /// identifier。宣言と一致しないと描画されない。
    static let materializedDecoration = NSFileProviderItemDecorationIdentifier(
        "org.izukawa.Tide.materialized")

    private let node: ManifestTree.Node
    private let materialized: Bool

    /// - Parameter materialized: 実体化バッジ（Issue #65）。file = 報告済み集合に掲載 /
    ///   dir = 配下 1 ファイル以上かつ全実体化（`BadgeFlags` で判定）。省略時 false = バッジなし
    ///   （root・仮想フォルダ等、構造的にバッジが付かない構築箇所用）。**報告済みでありうる item を
    ///   false で返すとバッジが消えたまま固着する**（メタデータ regress は次の差分が出るまで
    ///   再配信されない）ので、ツリー由来の item は `BadgeFlags` 経由で構築すること。
    init(node: ManifestTree.Node, materialized: Bool = false) {
        self.node = node
        self.materialized = materialized
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(tideNode: node)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let components = node.path.split(separator: "/")
        guard components.count > 1 else { return .rootContainer }
        // 親は常に合成ディレクトリ
        return NSFileProviderItemIdentifier(
            tideRelativePath: components.dropLast().joined(separator: "/"), isDirectory: true)
    }

    var filename: String {
        node.path.isEmpty ? "Tide" : node.name
    }

    var contentType: UTType {
        switch node {
        case .directory:
            return .folder
        case .file(let path, _):
            let ext = (path as NSString).pathExtension
            return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
        }
    }

    var capabilities: NSFileProviderItemCapabilities {
        switch node {
        case .directory(let path, _):
            // M5 Phase 5-3: 配下への新規作成と dir 削除（再帰）、Phase 5-4: 改名/移動、
            // Issue #105: evict（「ダウンロードを削除」= 配下のオンラインのみ化。ダエモン側処理・
            // 拡張コールバック不要）を解放。root は削除・改名・移動・evict 不可
            // （root evict = 全量オンラインのみ化は Keep Downloaded ピンとの相互作用が未検証の
            // ため保守側・ユーザ確定 2026-08-12）。
            // capabilities の変更は既存レプリカへ自動反映されない = ドメイン作り直し必須
            // （5-3 受け入れ知見①・作り直し前レジストリは #104 の epoch リセットが破棄）。
            var caps: NSFileProviderItemCapabilities = [
                .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
            ]
            if !path.isEmpty {
                caps.insert(.allowsDeleting)
                caps.insert(.allowsRenaming)
                caps.insert(.allowsReparenting)
                caps.insert(.allowsEvicting)
            }
            return caps
        case .file:
            // M5 Phase 5-2: 内容編集と削除、Phase 5-4: 改名/移動、Issue #105: evict を解放。
            return [
                .allowsReading, .allowsWriting, .allowsDeleting,
                .allowsRenaming, .allowsReparenting, .allowsEvicting,
            ]
        }
    }

    var itemVersion: NSFileProviderItemVersion {
        // 符号化は TideCore の `FileProviderWritePolicy` に集約（`baseSha` の対・書込経路の
        // 3-way ベース抽出と往復整合を保証。PR #58 レビュー #8）。
        // - contentVersion: file = sha256 / dir = "dir"。**実体化フラグは絶対に載せない**
        //   （内容変化の意味になり再取得を誘発する）。
        // - metadataVersion: file = sha256（+ 実体化時 `|m`）/ dir = "dir-<mtime>"（+ `|m`）。
        //   file の **sha プレフィックスは load-bearing**（M5 Phase 5-4）: rebind（move の返却
        //   item で id を変えた）item への次操作は、システムが渡す baseVersion の contentVersion が
        //   ローカル版スタンプに差し替わる（実機確定）。`FileProviderWritePolicy.baseSha` は
        //   metadataVersion から sha を復元してベースガードを維持するため、sha を先頭に持たない
        //   符号化に変えると rebind 後の削除/編集が全滅する（`|m` サフィックスは baseSha が
        //   剥がして復元する = 往復は `FileProviderWritePolicyTests` が固定）。
        NSFileProviderItemVersion(
            contentVersion: FileProviderWritePolicy.contentVersion(for: node),
            metadataVersion: FileProviderWritePolicy.metadataVersion(
                for: node, materialized: materialized)
        )
    }

    var documentSize: NSNumber? {
        if case .file(_, let entry) = node { return NSNumber(value: entry.size) }
        return nil
    }

    var contentModificationDate: Date? {
        switch node {
        case .file(_, let entry):
            return ISO8601.parse(entry.mtime)
        case .directory(_, let mtime):
            // 合成 mtime（配下ファイルの最大値）。無指定 nil のままだと Finder が 1970 を
            // 表示する（Phase 3 PoC の既知の癖）。
            return mtime
        }
    }

    var contentPolicy: NSFileProviderContentPolicy {
        // dataless PoC の本旨: 実体はダウンロードせずプレースホルダのまま（開いた時に fetch）
        .downloadLazily
    }

    /// 実体化バッジ（Issue #65）: 実体化されているときだけチェックを出す。静的バッジ
    /// （全ファイル常時表示）は dataless にも付いて「ローカルに実体がある」と誤読されるため
    /// 不採用（2026-07-12 試作 → 撤去の経緯・docs/09）。
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        materialized ? [Self.materializedDecoration] : nil
    }
}

/// ツリー + 報告済み集合から、node ごとの実体化フラグを引いて item を構築するコンテキスト
/// （Issue #65）。dir の集計（配下全実体化）は **dir ノードを初めて判定したときだけ**計算し
/// （lazy・1 回きり）、以後使い回す — `item(for:)` は単一 item の照会ごとに BadgeFlags を
/// 作るため、eager 計算だとファイル照会でも毎回 O(全ファイル数) の集計を踏む
/// （PR #66 レビュー perf 提案。fileproviderd は item(for:) をバースト発行することがある）。
/// 判定本体は TideCore の `MaterializedBadge`（純粋・テスト可能層）。
/// 単一 Task 内で生成・消費するローカルな文脈（Sendable 越境しない）。
final class BadgeFlags {
    private let tree: ManifestTree
    private let reported: Set<String>
    private lazy var checkedDirs: Set<String> = MaterializedBadge.checkedDirectories(
        filePaths: tree.filePaths, materialized: reported)

    /// - Parameter reported: Finder へ報告する（した）実体化済みファイルパス集合。
    ///   working set の enumerateChanges では newReport、読み取り経路では
    ///   `materializedReported.snapshot()` を渡す。
    init(tree: ManifestTree, reported: Set<String>) {
        self.tree = tree
        self.reported = reported
    }

    func isOn(_ node: ManifestTree.Node) -> Bool {
        node.isDirectory ? checkedDirs.contains(node.path) : reported.contains(node.path)
    }

    func item(_ node: ManifestTree.Node) -> FileProviderItem {
        FileProviderItem(node: node, materialized: isOn(node))
    }
}
