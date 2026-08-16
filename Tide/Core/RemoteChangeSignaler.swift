import TideCore
import Foundation
import Network
import Observation
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
@Observable
final class RemoteChangeSignaler {
    /// `.tide/index.json` の現行 ETag を返す（不在なら nil）。プロダクションは
    /// `S3Client.headObject` を配線し、テストはフェイクを注入する（依存注入の直接駆動面）。
    @ObservationIgnored private let headIndexETag: @Sendable () async throws -> String?
    /// 変化時の通知先。プロダクションは `FileProviderController.signalRemoteChanges()`
    /// （coalesce は向こう側が持つ）。
    @ObservationIgnored private let signal: () -> Void
    /// FP ドメインの状態（Issue #82 / #103）。プロダクションは `FileProviderController.domainStatus()`
    /// （fileproviderd へのローカル XPC 1 発・userEnabled 込み）を配線し、テストはフェイクを注入
    /// する。nil = 取得失敗。有効判定（アイコン用の fail-safe = nil も無効側）は signaler 内で
    /// `== .enabled` に畳むが、**生の status もエッジフックへ流す** — 通知の発火を
    /// 「.userDisabled の実観測」に限定するため（PR #109 収束レビュー ブロッカー 1・2）。
    @ObservationIgnored private let fpDomainStatus: @Sendable () async -> FileProviderController.DomainStatus?
    /// 無効/復帰の**エッジ検出時のみ**呼ばれる追加フック（Issue #103）。引数 = (無効になったか,
    /// そのとき観測した status)。プロダクションは OS 通知の発火（無効 ∧ `.userDisabled` のみ —
    /// アプリ内 Disable〈`.notRegistered`〉はユーザ自身の意図的操作・取得失敗〈nil〉は一過性の
    /// 可能性があり、いずれも「System Settings でオフ」の通知は誤指示になる）/ 配達済み通知の
    /// 撤去（復帰）を配線する。既定は no-op（テスト互換・通知はエッジのみ = 連発にならない）。
    @ObservationIgnored private let onFPDomainDisabledEdge: (Bool, FileProviderController.DomainStatus?) -> Void
    @ObservationIgnored private let intervalSeconds: Int

    // UI 表示用の観測状態（B-1・fpOnly ポップオーバー）。判定ロジックは一切持たない読み出し専用。
    /// 最後に HEAD が成功した時刻（index 不在でも成功扱い = 到達性の観測）。
    private(set) var lastCheckedAt: Date?
    /// 最後に FP ドメインへ signal した時刻（ベースライン / 変化の両方）。
    private(set) var lastSignaledAt: Date?
    /// 直近の HEAD が失敗していれば true（成功で自動クリア。一過性か持続かは UI 側が時刻と併読）。
    private(set) var lastCheckFailed = false
    /// 直近の観測で FP ドメインが無効（システム設定 OFF / 未登録）なら true。false = 無効が
    /// 観測されていない（有効 or 未観測。起動直後に誤ってエラー系アイコンを出さない側に倒す）。
    /// fpOnly では拡張が唯一の同期実体のため、無効 = 全同期停止なのに HEAD 到達性は正常のまま
    /// = 無エラー乖離の盲点（Issue #82）。メニューバーアイコンへ `fpOnlyHeadline` 経由で反映する。
    private(set) var fpDomainDisabled = false

    @ObservationIgnored private var lastETag: String?
    @ObservationIgnored private var hasBaseline = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserverTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// 多重チェックの coalesce（poll と wake の重なり等）。@MainActor なので check-and-set は
    /// 割り込まれない。進行中に届いた契機はドロップでよい（定期契機が必ず後続する）。
    @ObservationIgnored private var isChecking = false

    init(
        intervalSeconds: Int,
        headIndexETag: @escaping @Sendable () async throws -> String?,
        signal: @escaping () -> Void,
        fpDomainStatus: @escaping @Sendable () async -> FileProviderController.DomainStatus?,
        onFPDomainDisabledEdge: @escaping (Bool, FileProviderController.DomainStatus?) -> Void = { _, _ in }
    ) {
        self.intervalSeconds = intervalSeconds
        self.headIndexETag = headIndexETag
        self.signal = signal
        self.fpDomainStatus = fpDomainStatus
        self.onFPDomainDisabledEdge = onFPDomainDisabledEdge
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

        await observeFPDomainEnabled(reason: reason)

        let etag: String?
        do {
            etag = try await headIndexETag()
        } catch {
            // 保持 ETag は進めない＝復旧後の次契機で必ず差分検出できる。
            // reason は固定ラベル（startup/poll/wake/networkUp）なので .public（PR #75 レビュー任意 4:
            // 切替後ライブ soak の主観測点 = どの契機で何が起きたかを Info ログ消滅前に追えるようにする）。
            lastCheckFailed = true
            AppLogger.sync.error("RemoteChangeSignaler: HEAD index failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .private)")
            return
        }
        lastCheckFailed = false
        lastCheckedAt = Date()
        // index 不在 = 未セットアップ / 空バケット。ベースラインも作らない（初出現を変化として拾う）。
        guard let etag else { return }

        if !hasBaseline {
            // 初回はベースライン確立 + 無条件で 1 回 signal: アプリ停止中に溜まったリモート変化を
            // 拡張に取り込ませる保険（変化が無ければ拡張側の世代キャッシュで no-op・XPC 2 回だけ）。
            hasBaseline = true
            lastETag = etag
            signal()
            lastSignaledAt = Date()
            AppLogger.sync.info("RemoteChangeSignaler: baseline established (\(reason, privacy: .public)); signaled FP domain")
            return
        }
        guard etag != lastETag else { return }
        lastETag = etag
        signal()
        lastSignaledAt = Date()
        AppLogger.sync.info("RemoteChangeSignaler: index changed (\(reason, privacy: .public)); signaled FP domain")
    }

    /// FP ドメイン有効性の併観測（Issue #82）: HEAD と同契機・ローカル XPC 1 発。ログは
    /// エッジ検出時のみ（毎周回出すとノイズ床を上げる = #81 と同方針）。HEAD より先に観測する
    /// （拡張 OFF の検出は S3 到達性と独立 = オフラインでも気づける）。
    private func observeFPDomainEnabled(reason: String) async {
        let status = await fpDomainStatus()
        // アイコン側の有効判定は従来どおり fail-safe（nil = 取得失敗も無効側に倒す）。
        let enabled = status == .enabled
        if fpDomainDisabled && enabled {
            // 復帰エッジでは必ず 1 回 signal する: 無効期間中も HEAD は ETag を進めており
            // （その間の signal は FileProviderController 側の domainStatus ガードで no-op）、
            // 次の ETag 変化まで取り込み契機が来ない「見逃し窓」をここで閉じる。
            // 変化が無ければ拡張側の世代キャッシュで no-op（XPC 2 回だけ）。
            fpDomainDisabled = false
            signal()
            lastSignaledAt = Date()
            AppLogger.sync.notice("RemoteChangeSignaler: FP domain re-enabled (\(reason, privacy: .public)); signaled FP domain to catch up")
            onFPDomainDisabledEdge(false, status)
        } else if !fpDomainDisabled && !enabled {
            // fpOnly では拡張 OFF = 全同期停止。エラーがどこにも出ない盲点なので、ここだけは
            // .error で 1 回残す（エッジ検出 = 恒常ノイズにはならない）。
            fpDomainDisabled = true
            AppLogger.sync.error("RemoteChangeSignaler: FP domain is disabled (\(reason, privacy: .public)) — nothing is syncing until it is re-enabled")
            onFPDomainDisabledEdge(true, status)
        }
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
