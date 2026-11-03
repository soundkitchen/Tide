import FileProvider
import Foundation
import TideCore

// item identifier と Tide のパスの対応（FileProviderExtension.swift から切り出し・#162）。
// `FileProviderItem` と一緒に TideTests でもコンパイルする（project.yml の TideTests の sources）。

extension NSFileProviderItemIdentifier {
    /// Tide の item identifier のプレフィックス（M5 Phase 5-1 で kind 織り込み形式へ変更）:
    /// ファイル = `f:<相対 POSIX パス>` / ディレクトリ = `d:<相対 POSIX パス>` /
    /// パッケージ = `k:<相対 POSIX パス>`（#140）。ルートは
    /// `.rootContainer`。予約 identifier（rootContainer 等の rawValue）と同名ファイルとの
    /// 衝突回避（旧 `p:` の目的）も引き続きプレフィックスが担う。
    ///
    /// kind を id に織り込む理由: fileproviderd は同一 id の kind（file⇄dir）変化を受理しない —
    /// 単一レスポンス内の delete+update も、moreComing ページ分割も、自己 signal による
    /// 別セッション（22ms 差）でも「item changed」の ingest バッチに合成され delete が update を
    /// 打ち消す（item 消失。2026-07-05〜06 実機確定）。kind ごとに別 id なら kind 変化 =
    /// 「旧 id の削除 + 新 id の出現」となり、同一 id 合成の余地が構造的に消える。
    /// **旧 `p:` 形式の有効化済みドメインは Disable → Enable で作り直す**（docs/09 の
    /// 「identifier スキーマを変えたら作り直し」どおり。実験的 opt-in 機能のため移行コードは
    /// 持たない — 旧 id は `tidePathAndKind == nil` → noSuchItem に落ちる）。
    static let tideFilePrefix = "f:"
    static let tideDirectoryPrefix = "d:"
    /// パッケージ = `k:<相対 POSIX パス>`（#140）。ファイルとも別の id にする — Keynote は同じ名前の
    /// 書類を単一ファイル ⇄ パッケージで保存し直せるので、`f:` を共用すると同じ id の種類変化
    /// （fileproviderd の `doc` ⇄ `pkg`）になる（ユーザ確定 2026-10-30）。
    static let tidePackagePrefix = "k:"

    /// Tide の item identifier → (相対 POSIX パス, 種類)。ルートは `("", .directory)`。
    /// working set / trash / 旧 `p:` / 未知の identifier は nil。
    /// 裸の `"f:"` / `"d:"` / `"k:"`（空パス）も nil = 不正 id（root の正規表現は `.rootContainer` のみ。
    /// 受理すると root 高速パス等が「要求 id と食い違う item」を成功応答しうる。自前の mint 経路は
    /// この形を作らないが、書込対応でデーモン供給 id を受ける面が増える前の防御。PR #57 レビュー #5）。
    var tidePathAndKind: TideItemRef? {
        if self == .rootContainer { return TideItemRef(path: "", kind: .directory) }
        for (prefix, kind) in [
            (Self.tideFilePrefix, ManifestTree.Node.Kind.file),
            (Self.tideDirectoryPrefix, .directory),
            (Self.tidePackagePrefix, .package),
        ] where rawValue.hasPrefix(prefix) {
            let path = String(rawValue.dropFirst(prefix.count))
            return path.isEmpty ? nil : TideItemRef(path: path, kind: kind)
        }
        return nil
    }

    /// 相対 POSIX パス + 種類 → Tide の item identifier。ルート（`""`）は `.rootContainer`。
    init(tideRelativePath path: String, kind: ManifestTree.Node.Kind) {
        if path.isEmpty {
            self = .rootContainer
        } else {
            let prefix: String
            switch kind {
            case .file: prefix = Self.tideFilePrefix
            case .directory: prefix = Self.tideDirectoryPrefix
            case .package: prefix = Self.tidePackagePrefix
            }
            self = NSFileProviderItemIdentifier(prefix + path)
        }
    }

    /// 相対 POSIX パス + ディレクトリか → Tide の item identifier（ファイルかディレクトリ）。
    init(tideRelativePath path: String, isDirectory: Bool) {
        self.init(tideRelativePath: path, kind: isDirectory ? .directory : .file)
    }

    /// ノード → item identifier（種類はノードから取る）。
    init(tideNode node: ManifestTree.Node) {
        self.init(tideRelativePath: node.path, kind: node.kind)
    }
}

/// item identifier を分解した結果（`NSFileProviderItemIdentifier.tidePathAndKind`）。
struct TideItemRef: Equatable {
    let path: String
    let kind: ManifestTree.Node.Kind
    var isDirectory: Bool { kind == .directory }
    var isPackage: Bool { kind == .package }
}
