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
/// - **どちらも推奨サイズの 10 倍ごとに分けて返す（Issue #131）**: File Provider は 1 回に受け取る件数を
///   推奨サイズの 100 倍までに制限し、超えると assert で拡張を abort する。全件を 1 回で返していた
///   頃は、ノード数が上限を超えると全再列挙のたびにクラッシュを繰り返して同期が止まった。
///   ページ / 途中の anchor の符号化と切り出しは `FileProviderEnumerationPaging`（TideCore）。
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let dirPath: String?
    private let services: ExtensionServices
    /// このインスタンスが最後に `enumerateItems` で提示したツリーの anchor。
    /// `currentSyncAnchor` はこれを返す — 提示内容と anchor がずれると、その間の
    /// 変更 diff が永遠に報告されない窓ができる。observer/completion はどのスレッドからも
    /// 呼ばれ得る契約なのでロックで守る。
    private let lastServedAnchor = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// ページ列挙で固定した世代のツリー（と working set の並び）。続きのページごとに世代ログから
    /// 組み立て直さないための 1 件だけの記憶（Issue #131）。
    private let pinnedItems = OSAllocatedUnfairLock<PinnedItems?>(initialState: nil)
    /// 分割中の差分（起点 → 目標）。続きのバッチごとに差分を計算し直さないための 1 件だけの記憶。
    private let pendingChanges = OSAllocatedUnfairLock<PendingChanges?>(initialState: nil)

    private struct PinnedItems: Sendable {
        let anchor: String
        let tree: ManifestTree
        /// working set のときだけ使う全ノード（ルート除く・path 昇順）。
        let workingSetNodes: [ManifestTree.Node]
    }

    private struct PendingChanges: Sendable {
        let origin: String
        let target: String
        let tree: ManifestTree
        let changes: ManifestTreeDiff.Changes
        /// 起点の世代のファイル一覧（最後のバッチのバッジ計算用）。続きのバッチで起点の世代を
        /// 世代ログから引き直さないために持つ（PR #132 レビュー N1: 起点は分割中で最も古い世代
        /// なので、大量書込の最中は目標より先にログから落ちて全再列挙に戻りやすい）。
        let originFilePaths: [String]
    }

    init(dirPath: String?, services: ExtensionServices) {
        self.dirPath = dirPath
        self.services = services
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let dirPath = self.dirPath
        let services = self.services
        let pageSize = FileProviderEnumerationPaging.size(suggested: observer.suggestedPageSize)
        // システムの初期ページ（ソート指定の定数）や読めないページは nil = 最初から。
        let requested = FileProviderEnumerationPaging.decodeItemPage(page.rawValue)
        // observer はどのスレッドから呼んでもよい契約（システム側で直列化される）なので、
        // 非 Sendable なまま Task へ箱で運ぶ。
        let boxed = UncheckedSendableBox(value: observer)
        Task { [lastServedAnchor, pinnedItems] in
            do {
                // 最初のページで世代を固定し、続きのページも同じ世代のツリーから返す
                // （2026-10-17 ユーザ確定）。提示内容と currentSyncAnchor が必ず一致する。
                let cached = pinnedItems.withLock { $0 }
                let pinned: PinnedItems
                if let requested, let cached, cached.anchor == requested.anchor {
                    // 続きのページで記憶が当たれば、今の世代は要らない（キャッシュの TTL 切れで
                    // S3 を読みに行き、一時的なエラーで列挙が途中で止まるのを避ける・PR #132 レビュー N5）。
                    pinned = cached
                } else {
                    let current = try await services.cache.current()
                    if let requested, requested.anchor != current.anchor {
                        guard let generation = await services.cache.generation(anchor: requested.anchor) else {
                            // 固定した世代が世代ログから落ちた（ページの途中で大量の書込が続いた）。
                            // pageExpired でシステムに最初のページからやり直してもらう。
                            AppLogger.fileProvider.notice("enumerateItems: pinned generation expired — restarting from the first page")
                            boxed.value.finishEnumeratingWithError(NSFileProviderError(.pageExpired))
                            return
                        }
                        pinned = Self.pin(
                            anchor: requested.anchor, tree: ManifestTree(files: generation.files),
                            workingSet: dirPath == nil)
                    } else if let cached, cached.anchor == current.anchor {
                        pinned = cached
                    } else {
                        pinned = Self.pin(anchor: current.anchor, tree: current.tree, workingSet: dirPath == nil)
                    }
                    pinnedItems.withLock { $0 = pinned }
                }
                let offset = requested?.offset ?? 0

                let nodes: [ManifestTree.Node]
                if let dirPath {
                    guard let children = pinned.tree.children(of: dirPath) else {
                        // マニフェスト外 dir: レジストリ登録済みの仮想フォルダ（M5 Phase 5-3 の
                        // 空フォルダ仮想受理）だけ空列挙で温存する。レジストリ外は noSuchItem —
                        // 無条件の空列挙は消えた dir を「実在する空 dir」に見せてしまう
                        //（item(for:) の合成 dir 限定と同じ理由・M5 Phase 5-4）。
                        pinnedItems.withLock { $0 = nil }
                        if await services.virtualDirs.contains(dirPath) {
                            lastServedAnchor.withLock { $0 = pinned.anchor }
                            boxed.value.finishEnumerating(upTo: nil)
                        } else {
                            boxed.value.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
                        }
                        return
                    }
                    nodes = children
                } else {
                    nodes = pinned.workingSetNodes
                }
                let page = FileProviderEnumerationPaging.slice(nodes, offset: offset, size: pageSize)
                // ページ列挙の始まりと終わり（Issue #131）。全再列挙が世代の進みに追いつけるかを
                // 実測できるよう、件数とページサイズを残す。
                if dirPath == nil, offset == 0 {
                    AppLogger.fileProvider.notice("enumerateItems: working set started (\(nodes.count) items, page size \(pageSize))")
                }
                if dirPath == nil, page.nextOffset == nil {
                    AppLogger.fileProvider.notice("enumerateItems: working set finished (\(nodes.count) items)")
                }
                if !page.items.isEmpty {
                    // 実体化バッジ（Issue #65）: 列挙 item は伝え済み（報告済み + 返却分）基準のフラグ付き。
                    // ここは読み取り専用（レジストリの前進は working set の enumerateChanges のみ）。
                    let told = await services.toldMaterialized()
                    let flags = BadgeFlags(tree: pinned.tree, told: told)
                    boxed.value.didEnumerate(page.items.map(flags.item))
                }
                lastServedAnchor.withLock { $0 = pinned.anchor }
                if let next = page.nextOffset {
                    boxed.value.finishEnumerating(upTo: NSFileProviderPage(
                        FileProviderEnumerationPaging.encode(.init(anchor: pinned.anchor, offset: next))))
                } else {
                    // 列挙を終えたら固定したツリーを手放す（working set の enumerator は常駐するので、
                    // 古い世代のツリーを持ち続けない・PR #132 レビュー N4）。
                    pinnedItems.withLock { $0 = nil }
                    boxed.value.finishEnumerating(upTo: nil)
                }
            } catch {
                AppLogger.fileProvider.error("enumerateItems failed: \(String(describing: error), privacy: .private)")
                boxed.value.finishEnumeratingWithError(error)
            }
        }
    }

    /// 列挙に使うツリーを固定する。working set はルートを除く全ノードを path 昇順に並べておく
    /// （決定的 = ページの offset が世代を固定している限り同じ item を指す）。
    private static func pin(anchor: String, tree: ManifestTree, workingSet: Bool) -> PinnedItems {
        let nodes = workingSet
            ? tree.nodesByPath.filter { !$0.key.isEmpty }.sorted { $0.key < $1.key }.map(\.value)
            : []
        return PinnedItems(anchor: anchor, tree: tree, workingSetNodes: nodes)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let dirPath = self.dirPath
        let services = self.services
        let batchSize = FileProviderEnumerationPaging.size(suggested: observer.suggestedBatchSize)
        let boxed = UncheckedSendableBox(value: observer)
        let anchorString = String(data: anchor.rawValue, encoding: .utf8)
        // 分割の途中の anchor（Issue #131）なら、起点・目標の世代と続きの位置を取り出す。
        let cursor = anchorString.flatMap(FileProviderEnumerationPaging.decodeChangeCursor)
        Task { [pendingChanges] in
            func expired() {
                AppLogger.fileProvider.notice("enumerateChanges: unknown sync anchor (expired) — full re-enumeration")
                boxed.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            }
            guard let originAnchor = cursor?.origin ?? anchorString else {
                expired()
                return
            }
            do {
                // 起点・目標の世代と差分を決める。
                // - 続きのバッチで記憶（pendingChanges）が当たれば、それをそのまま使う。起点の世代を
                //   世代ログから引き直さず、今の世代も読まない（PR #132 レビュー N1 / N5 / N6）。
                // - それ以外は起点の世代を世代ログから引く。未知（非 UTF-8・世代落ち・Phase 3 の静的
                //   anchor・ログ消失後）は syncAnchorExpired でシステムに全再列挙させる。
                // - 目標はふつう今の世代（signal 応答経路なので TTL を待たずリフレッシュ。バースト床は
                //   「呼び出し元と異なる世代のキャッシュ = diff を返せる」場合のみ効く — 同世代なら必ず
                //   再ロードし、変更前キャッシュで「変更なし」と誤答して signal を消費しない）。分割の
                //   途中なら、分割を始めたときの世代。
                let target: (anchor: String, tree: ManifestTree)
                let changes: ManifestTreeDiff.Changes
                let originFilePaths: [String]
                var currentAnchor: String?
                let pending = pendingChanges.withLock { $0 }
                if let cursor, let pending, pending.origin == cursor.origin, pending.target == cursor.target {
                    target = (pending.target, pending.tree)
                    changes = pending.changes
                    originFilePaths = pending.originFilePaths
                } else {
                    guard let origin = await services.cache.generation(anchor: originAnchor) else {
                        expired()
                        return
                    }
                    if let cursor {
                        let current = try await services.cache.current()
                        currentAnchor = current.anchor
                        if cursor.target == current.anchor {
                            target = (cursor.target, current.tree)
                        } else if let generation = await services.cache.generation(anchor: cursor.target) {
                            target = (cursor.target, ManifestTree(files: generation.files))
                        } else {
                            expired()
                            return
                        }
                    } else {
                        let current = try await services.cache.refreshedCurrent(callerAnchor: originAnchor)
                        currentAnchor = current.anchor
                        target = (current.anchor, current.tree)
                    }
                    originFilePaths = Array(origin.files.keys)
                    if target.anchor == originAnchor {
                        changes = ManifestTreeDiff.Changes(updated: [], deleted: [])
                    } else {
                        changes = ManifestTreeDiff.changes(from: ManifestTree(files: origin.files), to: target.tree)
                        let computed = PendingChanges(
                            origin: originAnchor, target: target.anchor, tree: target.tree,
                            changes: changes, originFilePaths: originFilePaths)
                        pendingChanges.withLock { $0 = computed }
                    }
                }
                let offset = cursor?.offset ?? 0
                let batch = FileProviderEnumerationPaging.batch(changes, offset: offset, size: batchSize)

                // 種別変化（file⇄dir）も単一セッションで安全に配れる（M5 Phase 5-1）:
                // item identifier が kind 織り込み形式（`f:`/`d:` + path）なので、kind 変化は
                // 「旧 kind ノード（旧 id）の delete + 新 kind ノード（新 id）の update」= 別 id の
                // 独立した 2 変化になる。同一 id の delete+update を fileproviderd が ingest 合成で
                // 打ち消す問題（単一レスポンス / moreComing ページ / 近接別セッションのすべてで
                // 実機確認）は id 分離で構造的に消える。分割の境界で同じ id の削除と更新が
                // 別の回に分かれることもない（1 つの id は削除か更新の一方にしか現れない）。
                if !batch.deleted.isEmpty {
                    boxed.value.didDeleteItems(
                        withIdentifiers: batch.deleted.map(NSFileProviderItemIdentifier.init(tideNode:))
                    )
                }

                if let next = batch.nextOffset {
                    // 途中のバッチ: マニフェストの差分だけを配る。バッジ（報告済み集合）は動かさない
                    // （最後のバッチでまとめて計算する）ので、item のフラグも今の伝え済み（報告済み +
                    // 返却分）基準。
                    if !batch.updated.isEmpty {
                        let told = await services.toldMaterialized()
                        let flags = BadgeFlags(tree: target.tree, told: told)
                        boxed.value.didUpdate(batch.updated.map(flags.item))
                    }
                    AppLogger.fileProvider.notice("enumerateChanges: batch \(batch.updated.count) updated / \(batch.deleted.count) deleted (more coming)")
                    boxed.value.finishEnumeratingChanges(
                        upTo: NSFileProviderSyncAnchor(FileProviderEnumerationPaging.encode(
                            .init(origin: originAnchor, target: target.anchor, offset: next))),
                        moreComing: true
                    )
                    return
                }
                pendingChanges.withLock { $0 = nil }

                // 実体化バッジ（Issue #65）: live（fileproviderd の実体化セット）と reported
                // （前回 Finder へ報告した集合）の差分を didUpdate へオーバーレイする。
                // **報告点（reported の前進）は working set（dirPath == nil）のみ** — コンテナ
                // enumerator が消費すると working set 経由の配信が空振りしてバッジが固着する。
                // anchor（マニフェスト世代）意味論とは独立の eventual（docs/09 の設計判断）。
                // 返却 item で「実体化済み」と伝えた分（Issue #138・`ReturnLedger`）は、ファイルは
                // 伝え済みとして数え、まだ観測で確認できていなければ live にも足す。
                let reported = await services.materializedReported.snapshot()
                let ledger = await services.materializedObserver.ledgerSnapshot()
                let pendingReturned = ledger.pending
                let told = reported.union(pendingReturned)
                var newReport = reported
                var badgeFiles: Set<String> = []
                var badgeDirs: Set<String> = []
                var badgeDeferred = false
                let isWorkingSet = (dirPath == nil)
                if isWorkingSet {
                    // プロセス起動後まだ didChange が来ていなければ一度だけ遅延観測を仕掛ける
                    //（結果が差分を持てば自己 signal → 次の enumerateChanges で配られる）。
                    if await services.materializedObserver.shouldStartInitialRefresh() {
                        let refreshServices = services
                        Task { await refreshServices.refreshMaterializedObservation() }
                    }
                    let live = (await services.materializedObserver.current() ?? reported)
                        .union(ledger.unconfirmed)
                    let filePaths = target.tree.filePaths
                    // 除外名への改名で後片付けを予約した path（フォルダなら配下ごと）はバッジを
                    // 伝え済みのまま凍結する（Issue #138: 予約から後片付けの削除までに旧 item の版を
                    // 変えて再通知すると、fileproviderd が旧名をディスクへ戻そうとして失敗し続け、
                    // 後片付けが来ない）。凍結した分は上限より優先して残す。
                    let frozen = await services.exclusionCleanups.snapshot()
                    let fullReport = MaterializedBadge.pinnedReport(
                        live: live.intersection(filePaths), told: told, frozen: frozen,
                        cap: ExtensionServices.materializedBadgeCap
                    )
                    // dirsBefore は origin（= Finder が最後に見た世代）のツリー基準で計算する
                    //（PR #66 レビュー指摘 1: 両側 current だと「ツリーだけが変わった」チェック
                    // 反転 — リモート削除で全実体化 / 古い mtime のリモート追加で dataless 混入、
                    // どちらも合成 mtime が動かずマニフェスト diff に dir が載らない — が対称差に
                    // 現れず固着する）。同一 anchor なら origin == current で従来と等価。
                    // ただし同じ差分の途中のバッチで配った dir は、Finder がそのとき配った
                    // 「目標ツリー × 報告済み集合」の状態を見ているので、そちらを基準にする
                    // （PR #132 レビュー B1）。
                    let deliveredDirectories: Set<String> = offset > 0
                        ? Set(changes.updated.prefix(max(offset - changes.deleted.count, 0))
                            .filter(\.isDirectory).map(\.path))
                        : []
                    let context = MaterializedBadge.ChangeContext(
                        oldFilePaths: target.anchor == originAnchor ? filePaths : originFilePaths,
                        newFilePaths: filePaths, previousReported: reported,
                        deliveredDirectories: deliveredDirectories, pendingReturned: pendingReturned)
                    // 1 回で配る件数をバッチの大きさ（推奨バッチサイズの 10 倍）に収める（Issue #131）。
                    // マニフェストの差分を配った残りの枠でバッジを進め、残りは自己 signal で次の
                    // enumerateChanges に回す。
                    let budget = batchSize - batch.deleted.count - batch.updated.count
                    if budget > 0 {
                        (newReport, badgeFiles, badgeDirs) = context.partialReport(
                            newReport: fullReport, budget: budget)
                    } else {
                        newReport = told
                        (badgeFiles, badgeDirs) = context.changedPaths(newReport: told)
                    }
                    badgeDeferred = newReport != fullReport
                }
                // item 構築は working set では newReport 基準、非 working set では伝え済み基準。
                // マニフェスト diff で再配信される item にも正しいバッジを載せるため、フラグの
                // 基準を didUpdate 全体で 1 つに揃える。
                let flags = isWorkingSet
                    ? BadgeFlags(tree: target.tree, reported: newReport)
                    : BadgeFlags(tree: target.tree, reported: reported, pendingReturned: pendingReturned)

                // バッジ差分のみの item（マニフェスト diff に載っていない path）を合流させる。
                let updatedPaths = Set(batch.updated.map(\.path))
                let badgeOnlyNodes = badgeFiles.union(badgeDirs)
                    .subtracting(updatedPaths)
                    .sorted().compactMap { target.tree.node(at: $0) }
                let updateItems = (batch.updated + badgeOnlyNodes).map(flags.item)
                if !updateItems.isEmpty {
                    boxed.value.didUpdate(updateItems)
                }
                if target.anchor == originAnchor {
                    // マニフェスト無変化。anchor は前進しない — 実体化状態は anchor の外の
                    // eventual オーバーレイ。
                    if !badgeOnlyNodes.isEmpty {
                        AppLogger.fileProvider.notice("enumerateChanges: badge-only update (\(badgeOnlyNodes.count) items)")
                    }
                    boxed.value.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                } else {
                    AppLogger.fileProvider.notice("enumerateChanges: \(batch.updated.count) updated / \(batch.deleted.count) deleted / \(badgeOnlyNodes.count) badge-only")
                    // 分割している間に新しい世代ができていれば、続けて取りに来てもらう。続きのバッチで
                    // 今の世代をまだ読んでいなければここで読む（読めなければ moreComing なし = 次の
                    // signal で取りに来る）。
                    if currentAnchor == nil {
                        currentAnchor = try? await services.cache.current().anchor
                    }
                    boxed.value.finishEnumeratingChanges(
                        upTo: NSFileProviderSyncAnchor(Data(target.anchor.utf8)),
                        moreComing: currentAnchor.map { $0 != target.anchor } ?? false
                    )
                }
                // replace は badge 配信の有無と独立に前進させる（PR #66 レビュー nit 1）:
                // 配信対象ゼロでも「ツリーから消えたパスが reported に残っているだけ」の
                // 差は起きえて、放置すると live != reported が恒常成立 → didChange のたびに
                // 空振り signal + 空の enumerateChanges が 1 周走る。replace 自体は
                // 同値なら内部で no-op。
                if isWorkingSet {
                    await services.materializedReported.replace(with: newReport)
                    // 観測で確認済みの返却分は newReport に反映済みなので台帳から外す（Issue #138）。
                    // ただし newReport に入れたのに replace の上限で切り詰められた分は、伝え済み
                    // （点灯で配った）なのに reported に残っていないので、台帳に残す（外すと伝え済みの
                    // 集合から落ち、次の配信で消灯を配らないまま食い違う = PR #142 レビュー指摘 7）。
                    let persisted = await services.materializedReported.snapshot()
                    await services.materializedObserver.fold(ledger.confirmedMarks.filter {
                        persisted.contains($0.key) || !newReport.contains($0.key)
                    })
                    if badgeDeferred {
                        // 配りきれなかったバッジは次の enumerateChanges で配る（Issue #131）。
                        services.signalWorkingSet()
                    }
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
