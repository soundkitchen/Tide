import TideCore
import Foundation
import Observation

/// 「Sync Activity」ウィンドウの状態（M4）。sync_log を新しい順にページングしながら表示する。
/// **ライブ更新はしない**（開時ロード + 手動 Refresh）: 診断面でリアルタイム性の要求が薄く、
/// ValueObservation はフィルタ × ページングカーソルとの整合（observation 中の append 位置）が
/// 複雑化するため。Version History と同じ手動更新モデルに揃える。
/// DB は引数で受ける（env 非依存 = temp DB だけで `SyncActivityModelTests` が完結する）。
@MainActor
@Observable
final class SyncActivityModel {
    static let pageSize = 200

    var entries: [SyncLogRecord] = []
    var selectedTypes: Set<SyncLogEventType> = Set(SyncLogEventType.allCases)
    var selectedEntryId: Int64? = nil
    var isLoading = false
    var hasMore = false
    var errorMessage: String? = nil

    /// フィルタ変更の連打や Refresh 連打で、古い await の復帰が新しい結果を上書きしないための
    /// 世代トークン（VersionHistoryModel.scanGeneration と同じパターン）。reload は「最新が勝つ」
    /// 方針なので isLoading での再入拒否はせず、復帰時に世代一致を確認して stale を捨てる。
    @ObservationIgnored private var generation = 0

    var selectedEntry: SyncLogRecord? {
        guard let id = selectedEntryId else { return nil }
        return entries.first { $0.id == id }
    }

    /// 初回 `.task` / Refresh / フィルタ変更時。カーソルをリセットして先頭ページを読み直す。
    func reload(db: LocalDatabase) async {
        generation += 1
        let gen = generation
        isLoading = true
        errorMessage = nil
        do {
            let page = try await db.fetchLogs(eventTypes: selectedTypes, limit: Self.pageSize)
            guard gen == generation else { return }
            entries = page.records
            hasMore = page.hasMore
            // 選択行がフィルタ後も残っていれば維持する（消えていたら解除）。
            if let id = selectedEntryId, !page.records.contains(where: { $0.id == id }) {
                selectedEntryId = nil
            }
        } catch {
            guard gen == generation else { return }
            errorMessage = String(describing: error)
        }
        if gen == generation { isLoading = false }
    }

    /// 末尾の id を beforeId カーソルに次ページを追記する。
    func loadMore(db: LocalDatabase) async {
        guard !isLoading, hasMore, let lastId = entries.last?.id else { return }
        let gen = generation
        isLoading = true
        do {
            let page = try await db.fetchLogs(
                eventTypes: selectedTypes, beforeId: lastId, limit: Self.pageSize
            )
            // 進行中に reload が走っていたら（世代前進）この続きページは stale なので捨てる。
            guard gen == generation else { return }
            entries.append(contentsOf: page.records)
            hasMore = page.hasMore
        } catch {
            guard gen == generation else { return }
            errorMessage = String(describing: error)
        }
        if gen == generation { isLoading = false }
    }

    func toggleFilter(_ type: SyncLogEventType, db: LocalDatabase) async {
        if selectedTypes.contains(type) {
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
        await reload(db: db)
    }
}
