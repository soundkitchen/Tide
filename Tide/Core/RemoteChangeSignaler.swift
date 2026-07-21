import TideCore
import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

/// FP-only 稼働モード（M5 Track B・方針確定 2026-07-22）のリモート変更検知。
/// `.tide/index.json` の HEAD ETag をポーリング間隔（+ wake / ネットワーク復帰の即時契機 =
/// `SyncEngine` の pull トリガと対称）で比較し、変化したときだけ FP ドメインの working set へ
/// signal する。実際の増分取り込み（変化シャードの GET・diff 配布）は拡張自身が
/// `enumerateChanges` で行うため、アプリ側の仕事は「変化があったらしい」の通知だけ。
///
/// 不変条件（docs/09 M5 節・確定済み設計）:
/// - **DB / shard_state に一切触れない**。folderSync 復帰時に SyncEngine の pull が
///   shard_state の etag 差分で「FP-only 期間中の変化」を増分検出できることがモード可逆性の要で、
///   ここで shard_state を進めると復帰後の差分取り込みが壊れる。HEAD 1 発（≒数十バイト）のみ。
/// - index 不在（未セットアップ / 空バケット）の間は何もしない。
/// - HEAD 失敗は保持 ETag を進めず次契機に任せる（一過性エラーで変化を取りこぼさない）。
@MainActor
final class RemoteChangeSignaler {
    /// `.tide/index.json` の現行 ETag を返す（不在なら nil）。プロダクションは
    /// `S3Client.headObject` を配線し、テストはフェイクを注入する（依存注入の直接駆動面）。
    private let headIndexETag: @Sendable () async throws -> String?
    /// 変化時の通知先。プロダクションは `FileProviderController.signalRemoteChanges()`
    /// （coalesce は向こう側が持つ）。
    private let signal: () -> Void
    private let intervalSeconds: Int

    private var lastETag: String?
    private var hasBaseline = false
    private var pollTask: Task<Void, Never>?
    private var wakeObserverTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// 多重チェックの coalesce（poll と wake の重なり等）。@MainActor なので check-and-set は
    /// 割り込まれない。進行中に届いた契機はドロップでよい（定期契機が必ず後続する）。
    private var isChecking = false

    init(
        intervalSeconds: Int,
        headIndexETag: @escaping @Sendable () async throws -> String?,
        signal: @escaping () -> Void
    ) {
        self.intervalSeconds = intervalSeconds
        self.headIndexETag = headIndexETag
        self.signal = signal
    }

    func start() {
        // 再入安全（PR #75 レビュー任意 3）: 呼び直しで旧タスクへの参照を失うと
        // キャンセル不能な永久ループが残るため、先に止めてから張り直す。
        stop()
        // 初回チェック: ベースライン確立 + 1 回 signal（下記 checkOnce 参照）。
        Task { [weak self] in await self?.checkOnce(reason: "startup") }
        startPollingTimer()
        startWakeObserver()
        startNetworkMonitoring()
        AppLogger.sync.info("RemoteChangeSignaler started (interval: \(self.intervalSeconds)s)")
    }

    func stop() {
        pollTask?.cancel()
        wakeObserverTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    deinit {
        // stop() を経ない破棄でもループタスク / NWPathMonitor を残さない（PR #75 レビュー任意 3。
        // ループは [weak self] なので self は解放されるが、タスク自体は次の sleep 満了まで生きる）。
        pollTask?.cancel()
        wakeObserverTask?.cancel()
        pathMonitor?.cancel()
    }

    /// 1 回分のチェック本体（テストから直接駆動する）。
    func checkOnce(reason: String) async {
        if isChecking { return }
        isChecking = true
        defer { isChecking = false }

        let etag: String?
        do {
            etag = try await headIndexETag()
        } catch {
            // 保持 ETag は進めない＝復旧後の次契機で必ず差分検出できる。
            // reason は固定ラベル（startup/poll/wake/networkUp）なので .public（PR #75 レビュー任意 4:
            // 切替後ライブ soak の主観測点 = どの契機で何が起きたかを Info ログ消滅前に追えるようにする）。
            AppLogger.sync.error("RemoteChangeSignaler: HEAD index failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .private)")
            return
        }
        // index 不在 = 未セットアップ / 空バケット。ベースラインも作らない（初出現を変化として拾う）。
        guard let etag else { return }

        if !hasBaseline {
            // 初回はベースライン確立 + 無条件で 1 回 signal: アプリ停止中に溜まったリモート変化を
            // 拡張に取り込ませる保険（変化が無ければ拡張側の世代キャッシュで no-op・XPC 2 回だけ）。
            hasBaseline = true
            lastETag = etag
            signal()
            AppLogger.sync.info("RemoteChangeSignaler: baseline established (\(reason, privacy: .public)); signaled FP domain")
            return
        }
        guard etag != lastETag else { return }
        lastETag = etag
        signal()
        AppLogger.sync.info("RemoteChangeSignaler: index changed (\(reason, privacy: .public)); signaled FP domain")
    }

    // MARK: - Triggers（SyncEngine の poll / wake / network 配線と同型）

    private func startPollingTimer() {
        let interval = intervalSeconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(interval)))
                if Task.isCancelled { return }
                await self?.checkOnce(reason: "poll")
            }
        }
    }

    private func startWakeObserver() {
        #if canImport(AppKit)
        wakeObserverTask = Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                if Task.isCancelled { return }
                await self?.checkOnce(reason: "wake")
            }
        }
        #endif
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        let lastSatisfied = LastSatisfiedHolder()
        monitor.pathUpdateHandler = { [weak self] path in
            let now = path.status == .satisfied
            let prev = lastSatisfied.swap(now)
            if now && !prev {
                Task { @MainActor [weak self] in
                    await self?.checkOnce(reason: "networkUp")
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}
