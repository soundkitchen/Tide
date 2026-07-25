import TideCore
import Foundation
import Observation

// MARK: - ログソース抽象（Issue #83）

/// Sync Activity のログソース差替点（Issue #83）。folderSync = DB（sync_log）/ fpOnly = FP 拡張の
/// 共有イベントログ（`FPEventLog`）を同一ウィンドウで表示する。ページング契約は
/// `LocalDatabase.fetchLogs` と同じ（id 降順・`beforeId` カーソル・limit 超過分で hasMore 判定）。
@MainActor
protocol SyncActivitySource {
    /// フッタ注記の種別（保持ポリシーがソースごとに違うため文言を差し替える）。
    var retentionNote: SyncActivityRetentionNote { get }
    /// フィルタチップに出すイベント種別（PR #90 レビュー nit 3）。folderSync は move を
    /// 一次イベントとして持たない（DB に現れない）ため、常に空のチップを出さない。
    var displayedEventTypes: [SyncLogEventType] { get }
    /// reload を跨いで id が安定か（PR #90 レビュー nit 2）。DB = AUTOINCREMENT で安定 /
    /// FP = 時系列 index の合成 id でローテーション世代破棄を跨ぐと前詰めされ、同値 id が
    /// 別レコードを指しうる。不安定ソースは reload で選択を無条件解除する。
    var hasStableIds: Bool { get }
    func fetchLogs(
        eventTypes: Set<SyncLogEventType>, beforeId: Int64?, limit: Int
    ) async throws -> LocalDatabase.SyncLogPage
}

/// 保持ポリシー注記の種別（DB = 30 日で自動削除 / FP = サイズ上限で古い順に破棄）。
enum SyncActivityRetentionNote {
    case databaseThirtyDays
    case fpSizeCapped
}

/// folderSync: 既存の DB（sync_log）をそのまま読む。
struct DatabaseActivitySource: SyncActivitySource {
    let db: LocalDatabase

    var retentionNote: SyncActivityRetentionNote { .databaseThirtyDays }
    /// folderSync は move を一次イベントとして持たない（delete + upload に分解）ため
    /// Moves チップは出さない。
    var displayedEventTypes: [SyncLogEventType] {
        SyncLogEventType.allCases.filter { $0 != .move }
    }
    var hasStableIds: Bool { true }

    func fetchLogs(
        eventTypes: Set<SyncLogEventType>, beforeId: Int64?, limit: Int
    ) async throws -> LocalDatabase.SyncLogPage {
        try await db.fetchLogs(eventTypes: eventTypes, beforeId: beforeId, limit: limit)
    }
}

/// fpOnly: FP 拡張の共有イベントログ（`FPEventLog`）を読み、`SyncLogRecord` へ写像して返す
/// （Issue #83）。id は時系列 index からの合成（最古 = 1 … 最新 = N）。reload（beforeId nil）で
/// ファイルを読み直してスナップショットを取り、loadMore はそのスナップショットからページング
/// する（読込の合間に拡張が追記してもカーソルがずれない）。ローテーション横断の絶対 id 安定性は
/// 持たない（診断ビュー・Refresh で再整列される）。
@MainActor
final class FPEventLogActivitySource: SyncActivitySource {
    private let log: FPEventLog
    /// 直近 reload 時点のスナップショット（新しい順・合成 id 付き）。
    private var snapshotDesc: [SyncLogRecord] = []

    init(log: FPEventLog) {
        self.log = log
    }

    var retentionNote: SyncActivityRetentionNote { .fpSizeCapped }
    var displayedEventTypes: [SyncLogEventType] { SyncLogEventType.allCases }
    var hasStableIds: Bool { false }

    func fetchLogs(
        eventTypes: Set<SyncLogEventType>, beforeId: Int64?, limit: Int
    ) async throws -> LocalDatabase.SyncLogPage {
        if beforeId == nil {
            let chronological = await log.loadRecords()
            snapshotDesc = Array(chronological.enumerated().map { index, record in
                SyncLogRecord(
                    id: Int64(index + 1),
                    timestamp: record.timestamp,
                    eventType: record.eventType,
                    path: record.path,
                    message: record.message,
                    details: record.details
                )
            }.reversed())
        }
        let selectedRaws = Set(eventTypes.map(\.rawValue))
        var filtered = snapshotDesc.filter { selectedRaws.contains($0.eventType) }
        if let beforeId {
            filtered = filtered.filter { ($0.id ?? 0) < beforeId }
        }
        return LocalDatabase.SyncLogPage(
            records: Array(filtered.prefix(limit)),
            hasMore: filtered.count > limit
        )
    }
}

// MARK: - モデル

/// 「Sync Activity」ウィンドウの状態（M4）。ログを新しい順にページングしながら表示する。
/// **ライブ更新はしない**（開時ロード + 手動 Refresh）: 診断面でリアルタイム性の要求が薄く、
/// ValueObservation はフィルタ × ページングカーソルとの整合（observation 中の append 位置）が
/// 複雑化するため。Version History と同じ手動更新モデルに揃える。
/// ソースは引数で受ける（env 非依存 = temp DB / temp ファイルだけでテストが完結する）。
/// folderSync = DB / fpOnly = FP 共有イベントログの差替は `SyncActivitySource`（Issue #83）。
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
    func reload(source: any SyncActivitySource) async {
        generation += 1
        let gen = generation
        isLoading = true
        errorMessage = nil
        do {
            let page = try await source.fetchLogs(
                eventTypes: selectedTypes, beforeId: nil, limit: Self.pageSize
            )
            guard gen == generation else { return }
            entries = page.records
            hasMore = page.hasMore
            // 選択行がフィルタ後も残っていれば維持する（消えていたら解除）。id が reload を
            // 跨いで安定しないソース（FP 合成 id）は、同値 id が別レコードを指したまま詳細
            // ペインに出るのを防ぐため無条件解除（PR #90 レビュー nit 2）。
            if !source.hasStableIds {
                selectedEntryId = nil
            } else if let id = selectedEntryId, !page.records.contains(where: { $0.id == id }) {
                selectedEntryId = nil
            }
        } catch {
            guard gen == generation else { return }
            errorMessage = String(describing: error)
        }
        if gen == generation { isLoading = false }
    }

    /// 末尾の id を beforeId カーソルに次ページを追記する。
    func loadMore(source: any SyncActivitySource) async {
        guard !isLoading, hasMore, let lastId = entries.last?.id else { return }
        let gen = generation
        isLoading = true
        do {
            let page = try await source.fetchLogs(
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

    func toggleFilter(_ type: SyncLogEventType, source: any SyncActivitySource) async {
        if selectedTypes.contains(type) {
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
        await reload(source: source)
    }
}
