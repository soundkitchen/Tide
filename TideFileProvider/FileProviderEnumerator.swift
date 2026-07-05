import FileProvider
import Foundation
import os
import TideCore

/// マニフェストツリー駆動の列挙（M5 Phase 3〜・読み取り専用）。
///
/// - `dirPath == nil` は working set: **ドメイン全 item をフラットに列挙**する（FruitBasket 方式）。
///   macOS の replicated 拡張ではリモート変更は working set の `enumerateChanges` 経由でのみ
///   システムへ届くため、working set がドメイン全体をカバーしていないと signal しても
///   列挙済みレプリカが恒久 stale になる（Phase 4 リサーチで確定）。
/// - `enumerateChanges` は世代 anchor（`ManifestGenerationCache`）ベース。未知/世代落ち anchor は
///   `.syncAnchorExpired` を返し、システムがキャッシュを破棄して全再列挙する（自己回復）。
///   Phase 3 の静的 anchor（"tide-poc-static"）もこの経路で自然に移行される。
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let dirPath: String?
    private let services: ExtensionServices
    /// このインスタンスが最後に `enumerateItems` で提示したツリーの anchor。
    /// `currentSyncAnchor` はこれを返す — 提示内容と anchor がずれると、その間の
    /// 変更 diff が永遠に報告されない窓ができる。observer/completion はどのスレッドからも
    /// 呼ばれ得る契約なのでロックで守る。
    private let lastServedAnchor = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(dirPath: String?, services: ExtensionServices) {
        self.dirPath = dirPath
        self.services = services
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let dirPath = self.dirPath
        let services = self.services
        // observer はどのスレッドから呼んでもよい契約（システム側で直列化される）なので、
        // 非 Sendable なまま Task へ箱で運ぶ。
        let boxed = UncheckedSendableBox(value: observer)
        Task { [lastServedAnchor] in
            do {
                let current = try await services.cache.current()
                let nodes: [ManifestTree.Node]
                if let dirPath {
                    guard let children = current.tree.children(of: dirPath) else {
                        boxed.value.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
                        return
                    }
                    nodes = children
                } else {
                    // working set: ルートを除く全ノード（path 昇順・決定的）
                    nodes = current.tree.nodesByPath
                        .filter { !$0.key.isEmpty }
                        .sorted { $0.key < $1.key }
                        .map(\.value)
                }
                if !nodes.isEmpty {
                    boxed.value.didEnumerate(nodes.map(FileProviderItem.init(node:)))
                }
                lastServedAnchor.withLock { $0 = current.anchor }
                boxed.value.finishEnumerating(upTo: nil)
            } catch {
                AppLogger.fileProvider.error("enumerateItems failed: \(String(describing: error), privacy: .private)")
                boxed.value.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let services = self.services
        let boxed = UncheckedSendableBox(value: observer)
        let anchorString = String(data: anchor.rawValue, encoding: .utf8)
        Task {
            guard let anchorString else {
                boxed.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            // 起点世代の解決。未知（世代落ち・Phase 3 の静的 anchor・ログ消失後）は
            // syncAnchorExpired でシステムに全再列挙させる。
            guard let origin = await services.cache.generation(anchor: anchorString) else {
                AppLogger.fileProvider.notice("enumerateChanges: unknown sync anchor (expired) — full re-enumeration")
                boxed.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            do {
                // signal 応答経路なので TTL を待たずリフレッシュ。バースト床は「呼び出し元と
                // 異なる世代のキャッシュ = diff を返せる」場合のみ効く（同世代なら必ず再ロード
                // — 変更前キャッシュで「変更なし」と誤答して signal を消費しないため）。
                let current = try await services.cache.refreshedCurrent(callerAnchor: anchorString)
                if current.anchor == anchorString {
                    boxed.value.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    return
                }
                // ドメイン全体の diff を報告する（コンテナ enumerator にも同じ diff を返す —
                // item は parentItemIdentifier を持つのでシステム側が正しく取り込む。FruitBasket 方式）。
                let changes = ManifestTreeDiff.changes(
                    from: ManifestTree(files: origin.files), to: current.tree
                )
                // 種別変化（file⇄dir）も単一セッションで安全に配れる（M5 Phase 5-1）:
                // item identifier が kind 織り込み形式（`f:`/`d:` + path）なので、kind 変化は
                // 「旧 kind ノード（旧 id）の delete + 新 kind ノード（新 id）の update」= 別 id の
                // 独立した 2 変化になる。同一 id の delete+update を fileproviderd が ingest 合成で
                // 打ち消す問題（単一レスポンス / moreComing ページ / 近接別セッションのすべてで
                // 実機確認）は id 分離で構造的に消える。
                if !changes.deleted.isEmpty {
                    boxed.value.didDeleteItems(
                        withIdentifiers: changes.deleted.map(NSFileProviderItemIdentifier.init(tideNode:))
                    )
                }
                if !changes.updated.isEmpty {
                    boxed.value.didUpdate(changes.updated.map(FileProviderItem.init(node:)))
                }
                AppLogger.fileProvider.notice("enumerateChanges: \(changes.updated.count) updated / \(changes.deleted.count) deleted")
                boxed.value.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(Data(current.anchor.utf8)), moreComing: false
                )
            } catch {
                AppLogger.fileProvider.error("enumerateChanges failed: \(String(describing: error), privacy: .private)")
                boxed.value.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // enumerateItems が最後に提示したツリーの anchor を返す（提示内容との整合が最優先）。
        // 未提示（システムが列挙前に anchor だけ要求した場合）は今の世代の anchor。
        if let served = lastServedAnchor.withLock({ $0 }) {
            completionHandler(NSFileProviderSyncAnchor(Data(served.utf8)))
            return
        }
        let services = self.services
        let boxed = UncheckedSendableBox(value: completionHandler)
        Task {
            let anchor = try? await services.cache.current().anchor
            boxed.value(anchor.map { NSFileProviderSyncAnchor(Data($0.utf8)) })
        }
    }
}
