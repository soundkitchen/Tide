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
                        // マニフェスト外 dir: レジストリ登録済みの仮想フォルダ（M5 Phase 5-3 の
                        // 空フォルダ仮想受理）だけ空列挙で温存する。レジストリ外は noSuchItem —
                        // 無条件の空列挙は消えた dir を「実在する空 dir」に見せてしまう
                        //（item(for:) の合成 dir 限定と同じ理由・M5 Phase 5-4）。
                        if await services.virtualDirs.contains(dirPath) {
                            lastServedAnchor.withLock { $0 = current.anchor }
                            boxed.value.finishEnumerating(upTo: nil)
                        } else {
                            boxed.value.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
                        }
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
                    // 実体化バッジ（Issue #65）: 列挙 item は報告済み集合基準のフラグ付き。
                    // ここは読み取り専用（レジストリの前進は working set の enumerateChanges のみ）。
                    let reported = await services.materializedReported.snapshot()
                    let flags = BadgeFlags(tree: current.tree, reported: reported)
                    boxed.value.didEnumerate(nodes.map(flags.item))
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
            // 起点世代の解決。未知（非 UTF-8・世代落ち・Phase 3 の静的 anchor・ログ消失後）は
            // syncAnchorExpired でシステムに全再列挙させる（単一 guard = どの経路でも必ず
            // notice ログを通す。PR #57 レビュー #4）。
            guard let anchorString,
                  let origin = await services.cache.generation(anchor: anchorString) else {
                AppLogger.fileProvider.notice("enumerateChanges: unknown sync anchor (expired) — full re-enumeration")
                boxed.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            do {
                // signal 応答経路なので TTL を待たずリフレッシュ。バースト床は「呼び出し元と
                // 異なる世代のキャッシュ = diff を返せる」場合のみ効く（同世代なら必ず再ロード
                // — 変更前キャッシュで「変更なし」と誤答して signal を消費しないため）。
                let current = try await services.cache.refreshedCurrent(callerAnchor: anchorString)

                // 実体化バッジ（Issue #65）: live（fileproviderd の実体化セット）と reported
                // （前回 Finder へ報告した集合）の差分を didUpdate へオーバーレイする。
                // **報告点（reported の前進）は working set（dirPath == nil）のみ** — コンテナ
                // enumerator が消費すると working set 経由の配信が空振りしてバッジが固着する。
                // anchor（マニフェスト世代）意味論とは独立の eventual（docs/09 の設計判断）。
                let reported = await services.materializedReported.snapshot()
                var newReport = reported
                var badgeFiles: Set<String> = []
                var badgeDirs: Set<String> = []
                let isWorkingSet = (dirPath == nil)
                if isWorkingSet {
                    // プロセス起動後まだ didChange が来ていなければ一度だけ遅延観測を仕掛ける
                    //（結果が差分を持てば自己 signal → 次の enumerateChanges で配られる）。
                    if await services.materializedObserver.shouldStartInitialRefresh() {
                        let refreshServices = services
                        Task { await refreshServices.refreshMaterializedObservation() }
                    }
                    let live = await services.materializedObserver.current() ?? reported
                    let filePaths = current.tree.filePaths
                    newReport = MaterializedBadge.cappedReport(
                        live: live.intersection(filePaths),
                        cap: ExtensionServices.materializedBadgeCap
                    )
                    // dirsBefore は origin（= Finder が最後に見た世代）のツリー基準で計算する
                    //（PR #66 レビュー指摘 1: 両側 current だと「ツリーだけが変わった」チェック
                    // 反転 — リモート削除で全実体化 / 古い mtime のリモート追加で dataless 混入、
                    // どちらも合成 mtime が動かずマニフェスト diff に dir が載らない — が対称差に
                    // 現れず固着する）。同一 anchor なら origin == current で従来と等価。
                    (badgeFiles, badgeDirs) = MaterializedBadge.changedPaths(
                        oldFilePaths: current.anchor == anchorString
                            ? filePaths : Array(origin.files.keys),
                        newFilePaths: filePaths,
                        previousReported: reported, newReport: newReport)
                }
                // item 構築は常に newReport 基準（非 working set では newReport == reported）。
                // マニフェスト diff で再配信される item にも正しいバッジを載せるため、フラグの
                // 基準を didUpdate 全体で 1 つに揃える。
                let flags = BadgeFlags(tree: current.tree, reported: newReport)

                if current.anchor == anchorString {
                    // マニフェスト無変化。バッジ差分だけあれば didUpdate で配る（anchor は
                    // 前進しない — 実体化状態は anchor の外の eventual オーバーレイ）。
                    let badgeNodes = badgeFiles.union(badgeDirs)
                        .sorted().compactMap { current.tree.node(at: $0) }
                    if !badgeNodes.isEmpty {
                        boxed.value.didUpdate(badgeNodes.map(flags.item))
                        AppLogger.fileProvider.notice("enumerateChanges: badge-only update (\(badgeNodes.count) items)")
                    }
                    boxed.value.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    // replace は badge 配信の有無と独立に前進させる（PR #66 レビュー nit 1）:
                    // 配信対象ゼロでも「ツリーから消えたパスが reported に残っているだけ」の
                    // 差は起きえて、放置すると live != reported が恒常成立 → didChange のたびに
                    // 空振り signal + 空の enumerateChanges が 1 周走る。replace 自体は
                    // 同値なら内部で no-op。
                    if isWorkingSet {
                        await services.materializedReported.replace(with: newReport)
                    }
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
                // バッジ差分のみの item（マニフェスト diff に載っていない path）を合流させる。
                let updatedPaths = Set(changes.updated.map(\.path))
                let badgeOnlyNodes = badgeFiles.union(badgeDirs)
                    .subtracting(updatedPaths)
                    .sorted().compactMap { current.tree.node(at: $0) }
                let updateItems = (changes.updated + badgeOnlyNodes).map(flags.item)
                if !updateItems.isEmpty {
                    boxed.value.didUpdate(updateItems)
                }
                AppLogger.fileProvider.notice("enumerateChanges: \(changes.updated.count) updated / \(changes.deleted.count) deleted / \(badgeOnlyNodes.count) badge-only")
                boxed.value.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(Data(current.anchor.utf8)), moreComing: false
                )
                if isWorkingSet {
                    await services.materializedReported.replace(with: newReport)
                }
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
