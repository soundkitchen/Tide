import FileProvider
import Foundation
import TideCore

/// 実体化バッジ（Issue #65）: fileproviderd から最後に観測した live 集合（実体化済みファイル
/// パス）の置き場。**メモリのみ**（拡張プロセスは短命だが、live は OS からいつでも全量を
/// 再取得できる真実なので永続化しない。永続化するのは「報告済み」= `PersistedPathSet` の側だけ）。
actor MaterializedObserver {
    private var live: Set<String>?
    private var initialRefreshStarted = false

    /// `materializedItemsDidChange` / 初回リフレッシュが観測した live 集合を置く。
    func update(_ paths: Set<String>) {
        live = paths
    }

    /// 最後に観測した live 集合。未観測（プロセス起動後にまだ didChange が来ていない）は nil —
    /// 呼び出し側は reported へフォールバックする（= 差分なし扱い・eventual）。
    func current() -> Set<String>? {
        live
    }

    /// 初回リフレッシュ（enumerateChanges 契機の遅延観測）を開始してよいか。一度きり true。
    func shouldStartInitialRefresh() -> Bool {
        guard live == nil, !initialRefreshStarted else { return false }
        initialRefreshStarted = true
        return true
    }
}

/// `NSFileProviderManager.enumeratorForMaterializedItems()` を全ページ駆動して、実体化済み
/// **ファイル**の相対パス集合を取り出す（Issue #65）。
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
