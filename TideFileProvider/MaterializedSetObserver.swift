import FileProvider
import Foundation
import TideCore

/// 実体化バッジ（Issue #65）: fileproviderd から最後に観測した live 集合（実体化済みファイル
/// パス）の置き場。**メモリのみ**（拡張プロセスは短命だが、live は OS からいつでも全量を
/// 再取得できる真実なので永続化しない。永続化するのは「報告済み」= `PersistedPathSet` の側だけ）。
/// 返却 item で「実体化済み」と伝えたファイルの台帳（Issue #138・`MaterializedBadge.ReturnLedger`）
/// も同じ actor に置く — 観測の番号と台帳の確認を同じ順序で進めるため。
actor MaterializedObserver {
    private var live: Set<String>?
    private var initialRefreshStarted = false
    private var ledger = MaterializedBadge.ReturnLedger()

    /// 実体化セットの観測を始める。返値は `update(_:query:)` に渡す。
    func beginQuery() -> UInt64 {
        ledger.beginQuery()
    }

    /// `materializedItemsDidChange` / 初回リフレッシュが観測した live 集合を置く。後から始まった
    /// 観測が先に反映されていたら捨てる（古い集合で live を戻さない）。
    func update(_ paths: Set<String>, query: UInt64) {
        guard ledger.shouldApply(query: query) else { return }
        live = paths
    }

    /// 最後に観測した live 集合。未観測（プロセス起動後にまだ didChange が来ていない）は nil —
    /// 呼び出し側は reported へフォールバックする（= 差分なし扱い・eventual）。
    func current() -> Set<String>? {
        live
    }

    /// 返却 item に実体化フラグを付けてよいかを決め、付けるなら台帳に記録する（Issue #138）。
    /// 判定（伝え済みの集合 = `reported` + 台帳）と記録を同じ actor の 1 回の呼び出しで行う —
    /// 分けると、上限の手前で並行したコールバックがどれも「入る」と判定して上限を超え、
    /// 超えた分が差分配信でフラグなしに再送される（PR #142 レビュー指摘 4）。
    func noteReturnedIfFits(
        _ path: String, reported: Set<String>, frozen: Set<String>, cap: Int
    ) -> Bool {
        guard MaterializedBadge.fitsReport(
            path: path, reported: reported, pendingReturned: ledger.pending,
            frozen: frozen, cap: cap)
        else { return false }
        ledger.noteReturned(path)
        return true
    }

    /// 台帳の今の状態（Issue #138）。報告点は `fold(_:)` に `confirmedMarks` を渡して畳み込む。
    func ledgerSnapshot() -> MaterializedBadge.ReturnLedger {
        ledger
    }

    /// 報告点が reported を前進させたので、確認済みの返却分を畳み込む（Issue #138）。
    func fold(_ marks: [String: UInt64]) {
        ledger.fold(marks)
    }

    /// 単一ファイルの move に追従する（reported の `renameSubtree` と揃える。追従しないと、次の
    /// 観測までの差分配信が移動先を未実体化として再送し、版が変わる = Issue #138 のちらつき）。
    func renameSubtree(from: String, to: String) {
        live = live.map { MaterializedBadge.renamingSubtree($0, from: from, to: to) }
        ledger.renameSubtree(from: from, to: to)
    }

    /// 削除に追従する（reported の `removeSubtree` と揃える）。
    func removeSubtree(at path: String) {
        live = live.map { MaterializedBadge.removingSubtree($0, at: path) }
        ledger.removeSubtree(at: path)
    }

    /// 初回リフレッシュ（enumerateChanges 契機の遅延観測）を開始してよいか。一度きり true。
    func shouldStartInitialRefresh() -> Bool {
        guard live == nil, !initialRefreshStarted else { return false }
        initialRefreshStarted = true
        return true
    }
}

/// `NSFileProviderManager.enumeratorForMaterializedItems()` を全ページ駆動して、実体化済み
/// **ファイル**（パッケージ含む・#140）の相対パス集合を取り出す（Issue #65）。
///
/// - ヘッダ仕様: 開始ページは `[NSData new]` 相当（`Data()`）。ソート定数は無効。
///   「システムが `materializedItemsDidChangeWithCompletionHandler` を呼んだら拡張側が列挙する」
///   という反転プロトコル。
/// - dir の item（実体化済みコンテナ）は捨てる: Tide の dir チェック基準は「配下全ファイル
///   実体化」（2026-07-14 ユーザ確定）で、OS の「dir が materialized = 子がディスク上に表現
///   されている（dataless 含む）」とは意味が異なる。dir 判定は `MaterializedBadge` が
///   ファイル集合から集計する。
/// - **個々のファイルの materialize/evict がこのセットに現れるかは実機検証項目**（SDK ヘッダは
///   dir 中心の記述。受け入れチェックリストの最初の項目にする）。観測数を notice ログに出し、
///   実機で `log show` から判定できるようにしておく。
enum MaterializedSetQuery {
    static func filePaths(domain: NSFileProviderDomain) async -> Set<String>? {
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        let enumerator = manager.enumeratorForMaterializedItems()
        var paths: Set<String> = []
        var fileCount = 0
        var totalCount = 0
        var page: NSFileProviderPage? = NSFileProviderPage(Data())
        while let currentPage = page {
            let result: Result<(ids: [NSFileProviderItemIdentifier], next: NSFileProviderPage?), Error> =
                await withCheckedContinuation { continuation in
                    let observer = MaterializedItemsCollector { outcome in
                        continuation.resume(returning: outcome)
                    }
                    enumerator.enumerateItems(for: observer, startingAt: currentPage)
                }
            switch result {
            case .success(let (ids, next)):
                totalCount += ids.count
                for id in ids {
                    // パッケージ（`k:`）はファイルと同じく 1 件の葉として数える（ツリーの `filePaths` と揃える）。
                    guard let ref = id.tidePathAndKind, !ref.isDirectory, !ref.path.isEmpty else {
                        continue
                    }
                    paths.insert(ref.path)
                    fileCount += 1
                }
                page = next
            case .failure(let error):
                AppLogger.fileProvider.error("materialized set enumeration failed: \(String(describing: error), privacy: .private)")
                return nil
            }
        }
        AppLogger.fileProvider.notice("materialized set: \(totalCount) items (\(fileCount) files)")
        return paths
    }
}

/// 1 ページ分の列挙結果を集める observer。システムは observer への呼び出しを直列化する契約
/// （既存 enumerator 実装と同じ前提）。resume は finish 系のどちらか一度だけ呼ばれる。
private final class MaterializedItemsCollector: NSObject, NSFileProviderEnumerationObserver,
    @unchecked Sendable
{
    private var ids: [NSFileProviderItemIdentifier] = []
    private let onFinish:
        (Result<(ids: [NSFileProviderItemIdentifier], next: NSFileProviderPage?), Error>) -> Void

    init(
        onFinish: @escaping (
            Result<(ids: [NSFileProviderItemIdentifier], next: NSFileProviderPage?), Error>
        ) -> Void
    ) {
        self.onFinish = onFinish
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        ids.append(contentsOf: updatedItems.map(\.itemIdentifier))
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        onFinish(.success((ids, nextPage)))
    }

    func finishEnumeratingWithError(_ error: Error) {
        onFinish(.failure(error))
    }
}
