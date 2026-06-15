import Foundation
import GRDB
import Network
import Observation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class SyncEngine {
    // MARK: - Observable state

    var status: SyncStatus = .notConfigured
    var lastSyncedAt: Date?
    var lastRemoteCheckedAt: Date?
    var queueDepth: Int = 0
    /// UI に見せる直近のエラー（構造化・上限 50）。生のエラー文字列は `SyncIssue.rawDetail` に
    /// 隔離し、既定表示は分類サマリのみ（F4 / H2 UI 残の解消）。
    var recentIssues: [SyncIssue] = []

    /// 現在有効な `.syncignore` のパターン行（Settings 表示用）。
    var activeIgnorePatterns: [String] = []

    /// 進行中の転送（メニューバーのポップオーバー表示用）。off-main の Uploader / Downloader が
    /// `@Sendable` reporter を通じて MainActor で更新する。(path, direction) で一意。
    var activeTransfers: [TransferProgress] = []

    /// リモート pull が進行中か。並行 pull を禁止する単一ゲート（triggerRemotePull）の実体であり、
    /// メニューバーの「Pull from S3」ボタンの進行表示（スピナー + Pulling…）にも使う（PR #9 レビュー ④）。
    private(set) var isRemotePulling: Bool = false

    // MARK: - Dependencies

    private let db: LocalDatabase
    private let s3: TideS3Client
    private let syncRoot: URL
    private let deviceId: String
    private let tmpDir: URL
    private let config: ConfigStore
    /// 競合 / 未バックアップ確定を OS 通知で知らせる（注入・テストでは nil）。
    private let notifier: (any SyncNotifying)?

    // MARK: - Internals

    private var watcher: FileWatcher?
    private var debouncer: DebounceQueue<FileChangeEvent>?
    private var watchTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var wakeObserverTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// pull 進行中に手動「Pull from S3」が押されたら立て、現 pull 終了後にもう 1 周する（coalescing）。
    @ObservationIgnored private var pendingManualPull: Bool = false
    private var paused: Bool = false
    private var running: Bool = false
    private var ignoreMatcher: SyncIgnoreMatcher = .empty
    /// 読込中に変化し続けて安定しないファイル（L6 A-detect の延期対象）で、既に「未バックアップ」警告を
    /// 出した path。recentIssues への重複表示を防ぐ。キューから消えた path はアイドル周回で間引く
    /// （= 安定して同期完了 or 除去されたら再エピソードでまた警告できる）。
    @ObservationIgnored private var unstableWarned: Set<String> = []

    /// 帯域制御（サブ E）。アップロード／ダウンロードでそれぞれ 1 つ保持し、全並行転送
    /// （複数ファイル並行・マルチパート並列）が**同一インスタンスを共有**して合計が上限に収まる。
    /// レートは `refreshBandwidthLimits()` が config から周回ごとに更新する（Settings 変更を次周回で反映）。
    private let uploadLimiter: RateLimiter
    private let downloadLimiter: RateLimiter

    /// 不安定ファイルの再検査の最小間隔（秒）。書込が落ち着くまでの最短待ち。
    /// nonisolated: 純粋ヘルパ `unstableRetryDelay`（テスト用に nonisolated）から参照するため。
    nonisolated private static let unstableQuiescenceSeconds: TimeInterval = 3
    /// この秒数を超えて安定しない（保留が続く）ら「未バックアップ」を 1 回ユーザに見せる。
    nonisolated private static let unstableWarnThresholdSeconds: TimeInterval = 30

    let pollIntervalSeconds: Int

    init(
        db: LocalDatabase,
        s3: TideS3Client,
        syncRoot: URL,
        deviceId: String,
        config: ConfigStore,
        pollIntervalSeconds: Int = 180,
        notifier: (any SyncNotifying)? = nil
    ) {
        self.db = db
        self.s3 = s3
        self.syncRoot = syncRoot
        self.deviceId = deviceId
        self.config = config
        self.notifier = notifier
        self.pollIntervalSeconds = max(30, pollIntervalSeconds)
        // 帯域制御（サブ E）: config の bytes/sec で初期化（既定 -1 = 無制限）。
        self.uploadLimiter = RateLimiter(ratePerSec: Double(config.uploadBandwidthBytesPerSec))
        self.downloadLimiter = RateLimiter(ratePerSec: Double(config.downloadBandwidthBytesPerSec))

        let (tmp, usedFallback) = TideTmpDirectory.resolve(for: syncRoot)
        self.tmpDir = tmp
        AppLogger.sync.info("Tmp directory: \(tmp.path, privacy: .private) (fallback: \(usedFallback ? "yes" : "no", privacy: .private))")
        Self.cleanupOldFallbackIfUnused(syncRoot: syncRoot, currentTmpDir: tmp)
    }

    /// 旧バージョンが残した <syncRoot>/.tide/tmp/ を、現運用で使っていなければ掃除する。
    private static func cleanupOldFallbackIfUnused(syncRoot: URL, currentTmpDir: URL) {
        let stale = syncRoot.appendingPathComponent(".tide/tmp")
        guard currentTmpDir.standardizedFileURL != stale.standardizedFileURL else { return }
        let staleRoot = syncRoot.appendingPathComponent(".tide")
        guard FileManager.default.fileExists(atPath: staleRoot.path) else { return }
        // 安全側: 中身があれば消さない（手動の介入を尊重）
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(atPath: stale.path)) ?? []
        let rootKids = (try? fm.contentsOfDirectory(atPath: staleRoot.path)) ?? []
        if kids.isEmpty && rootKids.allSatisfy({ $0 == "tmp" }) {
            try? fm.removeItem(at: staleRoot)
            AppLogger.sync.info("Removed stale \(staleRoot.path, privacy: .private)")
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !running else { return }
        running = true
        status = .idle

        // 起動時のオーファン掃除（キュー/プル開始前に awaited で実施＝再開ロジックと競合させない）。
        await pruneOrphanTransfers()

        // FileWatcher
        let watcher = FileWatcher(rootURL: syncRoot)
        self.watcher = watcher
        let debouncer = DebounceQueue<FileChangeEvent>(interval: 2.0) { [weak self] _, event in
            await self?.handleDebounced(event)
        }
        self.debouncer = debouncer

        do {
            try watcher.start()
        } catch {
            // 生のエラー文字列は status に乗せない（分類サマリのみ）。詳細は recentIssues 側に残す。
            let issue = SyncIssueClassifier.classify(error: error)
            status = .error(issue.category.localizedLabel)
            await recordIssue(issue, logAs: "Failed to start file watcher")
            running = false
            return
        }

        watchTask = Task { [weak self] in
            guard let self else { return }
            for await event in watcher.events {
                if Task.isCancelled { return }
                await debouncer.submit(key: event.relativePath, value: event)
                _ = self
            }
        }

        // Full scan + queue loop
        queueTask = Task { [weak self] in
            await self?.runQueueLoop()
        }

        Task { [weak self] in
            await self?.reloadIgnoreMatcher()
            await self?.triggerFullScan()
            // 起動時 pull も他経路（poll/wake/network/手動）と同じ単一ゲートを通す
            // （triggerRemotePull 内の isRemotePulling で排他＝並行 DL を防止）。
            await self?.triggerRemotePull(reason: .startup)
        }

        startPollingTimer()
        startWakeObserver()
        startNetworkMonitoring()

        AppLogger.sync.info("SyncEngine started")
    }

    func stop() async {
        running = false
        watchTask?.cancel()
        queueTask?.cancel()
        pollTask?.cancel()
        wakeObserverTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        watcher?.stop()
        watcher = nil
        debouncer = nil
        activeTransfers = []
        status = .notConfigured
    }

    // MARK: - 転送進捗（メニューバー表示）

    /// off-main の Uploader / Downloader へ渡す進捗シンク。MainActor へホップして集約する。
    private func makeProgressReporter() -> TransferProgressReporter {
        { [weak self] event in
            Task { @MainActor in self?.applyProgress(event) }
        }
    }

    /// 進捗イベントを `activeTransfers` に反映する。集約ロジックは純粋関数
    /// `TransferProgress.reduce` に切り出し（out-of-order 耐性を `TransferProgressTests` で固定）。
    private func applyProgress(_ event: TransferProgressEvent) {
        activeTransfers = TransferProgress.reduce(activeTransfers, applying: event)
    }

    // MARK: - 起動時のオーファン掃除（サブ D-D5）

    /// 不要になった `transfer_state` 行を片付ける。best-effort（失敗しても起動は続行）。
    /// 本体は配線（分岐 → 実 I/O）まで回帰テストできるよう、依存を引数で受ける static 関数に
    /// 切り出してある（`TransferPruneTests`）。
    private func pruneOrphanTransfers() async {
        let s3 = self.s3
        await Self.pruneOrphanTransfers(
            db: db,
            store: TransferStateStore(db: db),
            syncRoot: syncRoot,
            now: Date(),
            abortUpload: { key, uploadId in
                try? await s3.abortMultipartUpload(key: key, uploadId: uploadId)
            }
        )
    }

    /// `pruneOrphanTransfers()` の本体。
    /// - upload: ローカルファイルが消えた行は宙ぶらりんの MPU を best-effort abort して削除。
    /// - download: tmp が消えた（または stale な）行は、シャードキャッシュを invalidate してから削除。
    ///   tmp あり・新しい行は再開可能として温存し、シャードキャッシュの invalidate のみ行う（再 arm）。
    /// - 両方向とも 7 日より古い行は失効扱い（S3 の `tide-abort-incomplete-multipart` と歩調を合わせる）。
    nonisolated static func pruneOrphanTransfers(
        db: LocalDatabase,
        store: TransferStateStore,
        syncRoot: URL,
        now: Date,
        abortUpload: @Sendable (_ key: String, _ uploadId: String) async -> Void
    ) async {
        let rows: [TransferStateRecord]
        do {
            rows = try await store.allEntries()
        } catch {
            AppLogger.sync.error("Transfer-state prune: list failed: \(String(describing: error), privacy: .private)")
            return
        }
        guard !rows.isEmpty else { return }

        let staleCutoff = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        for row in rows {
            let isStale = row.updatedAt < staleCutoff
            switch row.direction {
            case TransferDirection.upload.rawValue:
                let fileExists = (try? PathValidator.resolveSafely(relativePath: row.path, syncRoot: syncRoot))
                    .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                guard !fileExists || isStale else { continue }
                if let uploadId = row.uploadId {
                    await abortUpload("files/\(row.path)", uploadId)
                }
                try? await store.clearUpload(path: row.path)
                AppLogger.sync.info("Pruned orphan upload transfer: \(row.path, privacy: .private)")
            case TransferDirection.download.rawValue:
                let tmpMissing = row.tmpPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
                if !tmpMissing && !isStale {
                    // 再開可能（tmp あり・新しい）: 次回 pull で確実に reconcile されるよう、この path の
                    // シャードの shard_state キャッシュを「無効化」する。さもないと「シャードは取得済み（DL 完了前に
                    // ManifestReader が記録）＋ DL 未完で FileRecord 無し」のため pull が当該ファイルを
                    // 見落とし、Downloader の Range 再開に到達しない（中断ダウンロードの取り残し）。
                    // sentinel 化（空 etag・行は削除しない）の理由は LocalDatabase.invalidateShardCache の
                    // doc コメント参照（セッション中の DL 失敗時の再 arm と共通機構。PR #9 レビュー ②③）。
                    do {
                        try await db.invalidateShardCache(forPath: row.path)
                        AppLogger.sync.info("Re-arm resumable download (invalidated shard cache): \(row.path, privacy: .private)")
                    } catch {
                        // 失敗するとバグ②③の前提（次回 pull で再 fetch される）が崩れ取り残しが再発するので
                        // 無音にせず必ず可視化する（PR #9 レビュー ⑤）。
                        AppLogger.sync.error("Re-arm resumable download failed for \(row.path, privacy: .private): \(String(describing: error), privacy: .private)")
                    }
                    continue
                }
                // clear 分岐（tmp 消失 or stale）でも、行を落とす前にシャードキャッシュを invalidate する
                // （resumable 分岐と対称）。再開対象は無いが FileRecord も無いため、invalidate を欠くと
                // pull が当該ファイルを見落とし続け、シャードがリモートで変化するまで永久に再 DL されない
                // （受け入れテスト §6-2 で発見）。invalidate に失敗したら行を消さずに continue
                // （行が残れば次回起動の prune が再試行＝自己回復。先に行を消すと取り残しが再発する）。
                // トレードオフ: invalidate が恒久失敗し続けると stale tmp も残り続けるが、取り残し防止 >
                // tmp litter で許容（DB 恒久失敗時はより大きい問題が先に顕在化し、DB 回復で自己解消。PR #11 nit-3）。
                do {
                    try await db.invalidateShardCache(forPath: row.path)
                } catch {
                    AppLogger.sync.error("Prune orphan download: invalidate failed for \(row.path, privacy: .private): \(String(describing: error), privacy: .private)")
                    continue
                }
                if let tmp = row.tmpPath { try? FileManager.default.removeItem(atPath: tmp) }
                // 行の有無が自己回復（次回 prune の再試行）の判定材料なので、clear の成否どおりに
                // log を出し分ける（resumable 分岐と同じ流儀。PR #11 レビュー nit-2）。
                do {
                    try await store.clearDownload(path: row.path)
                    AppLogger.sync.info("Pruned orphan download transfer: \(row.path, privacy: .private)")
                } catch {
                    AppLogger.sync.error("Prune orphan download: clear failed for \(row.path, privacy: .private): \(String(describing: error), privacy: .private)")
                }
            default:
                // 未知の direction は安全側で除去する。direction は TransferDirection enum と DB の
                // CHECK 制約の二重で 'upload' | 'download' に限定されるため実際には到達不能だが、
                // （将来スキーマや破損 DB で）到達した場合も「download 行を落とす前に必ず invalidate」の
                // 不変条件を保つ（PR #11 レビュー Low-1。invalidate 失敗なら行を温存して次回再試行）。
                // 除去は clearUnknownDirections で行う（clearUpload/clearDownload は direction
                // フィルタ付きなので未知 direction 行にはマッチしない）。同一 path の正当な行は
                // それぞれ自分のイテレーションで処理されるのでここでは触らない。
                do {
                    try await db.invalidateShardCache(forPath: row.path)
                } catch {
                    AppLogger.sync.error("Prune unknown-direction transfer: invalidate failed for \(row.path, privacy: .private): \(String(describing: error), privacy: .private)")
                    continue
                }
                try? await store.clearUnknownDirections(path: row.path)
            }
        }
    }

    // MARK: - Triggers (timer / wake / network)

    private func startPollingTimer() {
        let interval = pollIntervalSeconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(interval)))
                if Task.isCancelled { return }
                await self?.triggerRemotePull(reason: .poll)
            }
        }
    }

    private func startWakeObserver() {
        #if canImport(AppKit)
        wakeObserverTask = Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                if Task.isCancelled { return }
                await self?.triggerRemotePull(reason: .wake)
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
                    await self?.triggerRemotePull(reason: .networkUp)
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }


    func pause() {
        paused = true
        status = .paused
    }

    func resume() {
        guard paused else { return }
        paused = false
        status = .idle
    }

    // MARK: - .syncignore

    /// `<syncRoot>/.syncignore` を読み直して除外マッチャと Settings 表示用パターンを更新する。
    func reloadIgnoreMatcher() async {
        let matcher = await Self.loadIgnoreMatcher(syncRoot: syncRoot)
        ignoreMatcher = matcher
        activeIgnorePatterns = matcher.sourceLines
        AppLogger.sync.info("Reloaded .syncignore: \(matcher.sourceLines.count) pattern(s)")
    }

    /// `.syncignore` を安全に読み込んでマッチャを構築する。無い/大きすぎる/symlink の時は空。
    private static func loadIgnoreMatcher(syncRoot: URL) async -> SyncIgnoreMatcher {
        let url: URL
        do {
            url = try PathValidator.resolveSafely(relativePath: ".syncignore", syncRoot: syncRoot)
        } catch {
            return .empty
        }
        return await Task.detached(priority: .utility) { () -> SyncIgnoreMatcher in
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return .empty }
            // セキュリティゲート: シンボリックリンクは絶対に追従しない
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                AppLogger.sync.error("Refusing to read symlinked .syncignore")
                return .empty
            }
            guard let data = try? Data(contentsOf: url) else { return .empty }
            if data.count > SyncIgnoreMatcher.maxBytes {
                AppLogger.sync.error(".syncignore too large (\(data.count) bytes); ignoring")
                return .empty
            }
            let text = String(decoding: data, as: UTF8.self)
            return SyncIgnoreMatcher.parse(text)
        }.value
    }

    // MARK: - Full scan

    func triggerFullScan() async {
        AppLogger.sync.info("Starting full scan: \(self.syncRoot.path, privacy: .private)")
        do {
            try await performFullScan()
        } catch {
            AppLogger.sync.error("Full scan failed: \(String(describing: error), privacy: .private)")
            await recordIssue(SyncIssueClassifier.classify(error: error), logAs: "Full scan failed")
        }
    }

    // MARK: - Restore（M4: 過去バージョン / 削除済みの復元）

    /// 指定 key（相対パス）の `versionId`（nil = 最新版）をローカルへ復元する（UI から呼ぶ）。
    /// 復元サービスは private 保持の db / syncRoot / tmpDir / downloadLimiter を共有する。
    /// 復元後はフルスキャンを促し、書き戻したファイルを通常 upload 経路で**新しい現行版**として上げ直す
    /// （= 復元 = 再アップロード。DB は復元サービス側で触らない）。重い DL は復元サービス内で off-main に走る。
    @discardableResult
    func restore(relativePath: String, versionId: String?) async throws -> RestoreService.RestoreResult {
        let service = RestoreService(
            client: s3, db: db, syncRoot: syncRoot, tmpDir: tmpDir, downloadLimiter: downloadLimiter
        )
        let result = try await service.restore(relativePath: relativePath, versionId: versionId)
        // 書き戻したファイルを拾わせる（FileWatcher の取りこぼし保険＝確実に再アップロードへ乗せる）。
        await triggerFullScan()
        return result
    }

    private func performFullScan() async throws {
        let root = self.syncRoot
        let dev = self.deviceId
        let db = self.db
        let matcher = self.ignoreMatcher
        let now = Date().timeIntervalSince1970

        let result: (newEnqueued: Int, deletedEnqueued: Int, mtimesRepaired: Int) = try await Task.detached(priority: .utility) { () -> (Int, Int, Int) in
            var foundPaths: Set<String> = []
            var newEnqueued = 0
            var deletedEnqueued = 0
            var mtimesRepaired = 0

            let fm = FileManager.default
            // hidden files (e.g. .git) はデフォルトで含める。skipsHiddenFiles を指定しない。
            let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey
                ],
                options: []
            )

            while let next = walker?.nextObject() as? URL {
                let values = try next.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey
                ])
                // C2: シンボリックリンクは絶対に追従しない（ディレクトリリンクなら配下もスキップ）
                if values.isSymbolicLink == true {
                    walker?.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true else { continue }

                let relative = Self.relativePath(of: next, root: root)
                // ハードコード除外は DB を読む前に弾く（大きな除外ツリーでの無駄な DB 読みを避ける）
                if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }
                // C1: 念のため相対パスを検証（root エスケープを防ぐ）
                do {
                    try PathValidator.validateRelativePath(relative)
                } catch {
                    continue
                }

                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0

                let existing = try await db.pool.read { db in
                    try FileRecord.fetchOne(db, key: relative)
                }

                // .syncignore のユーザパターン除外（既存追跡は触らない＝新規のみスキップ）。
                // スキップしたファイルは foundPaths に入れない（未追跡なので削除検出にも乗らない）。
                let tracked = (existing?.lastSyncedAt != nil)
                if IgnoreDecision.shouldSkip(relativePath: relative, isAlreadyTracked: tracked, matcher: matcher) {
                    continue
                }

                foundPaths.insert(relative)

                // 変更判定は ChangeDetector（純粋関数）に集約。size 一致 + mtime 不一致は SHA で
                // 「実変更か mtime ドリフトか」を判定し、ドリフトなら DB の mtime を修復して
                // 再アップロードしない（docs/04 仕様の SHA ゲート。マニフェスト秒精度 mtime での
                // DB 汚染や setAttributes 失敗の残差を自己修復する安全網）。
                let known = existing.map {
                    ChangeDetector.Known(
                        size: $0.size, mtime: $0.mtime,
                        sha256: $0.sha256, isSynced: $0.lastSyncedAt != nil
                    )
                }
                let needsEnqueue: Bool
                switch ChangeDetector.preDecision(known: known, size: size, mtime: mtime) {
                case .skip:
                    needsEnqueue = false
                case .enqueue:
                    needsEnqueue = true
                case .verifyHash:
                    // verifyHash は known 非 nil のときのみ返る（空 sha フォールバックは常に enqueue 側）。
                    let knownSha = known?.sha256 ?? ""
                    let computed = try? HashCalculator.sha256(of: next)
                    switch ChangeDetector.postHash(knownSha: knownSha, computedSha: computed) {
                    case .refreshMtimeOnly:
                        // CAS: 判定〜書込の間に並行 pull が同 path を更新していたら no-op
                        // （新しい sha / s3VersionId / s3Etag を巻き戻さない）。
                        // カウントは返値どおり = 実際に修復した行のみ（ログ "repaired N mtimes" は
                        // 自己修復の観測点なので no-op を数えない。PR #12 レビュー Low-1）。
                        if try await db.refreshMtimeIfShaUnchanged(
                            path: relative, expectedSha: knownSha, newMtime: mtime
                        ) {
                            mtimesRepaired += 1
                        }
                        needsEnqueue = false
                    case .enqueue:
                        needsEnqueue = true
                    }
                }

                if needsEnqueue {
                    try await db.pool.write { db in
                        var rec = UploadQueueRecord(
                            id: nil,
                            path: relative,
                            operation: "upload",
                            enqueuedAt: now,
                            attempts: 0,
                            nextRetryAt: nil,
                            lastError: nil
                        )
                        try rec.insert(db, onConflict: .ignore)
                    }
                    newEnqueued += 1
                }
                _ = dev
            }

            // DB にあって実体がないファイルを delete キューへ
            let knownPaths: Set<String> = try await db.pool.read { db in
                let all = try FileRecord.fetchAll(db)
                return Set(all.map { $0.path })
            }
            let missing = knownPaths.subtracting(foundPaths)
            if !missing.isEmpty {
                try await db.pool.write { db in
                    for p in missing {
                        var rec = UploadQueueRecord(
                            id: nil,
                            path: p,
                            operation: "delete",
                            enqueuedAt: now,
                            attempts: 0,
                            nextRetryAt: nil,
                            lastError: nil
                        )
                        try rec.insert(db, onConflict: .ignore)
                    }
                }
                deletedEnqueued = missing.count
            }

            return (newEnqueued, deletedEnqueued, mtimesRepaired)
        }.value

        AppLogger.sync.info("Full scan: enqueued \(result.newEnqueued) uploads, \(result.deletedEnqueued) deletes, repaired \(result.mtimesRepaired) mtimes")
        await refreshQueueDepth()
    }

    nonisolated static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(rootPath + "/") {
            return String(p.dropFirst(rootPath.count + 1))
        }
        return p
    }

    // MARK: - Remote pull

    /// リモート pull の契機。PR #9 ⑥ まではログ専用の文字列だったが、coalescing（PR #9 レビュー ④）で
    /// 「manual のみ pending 化」という制御フローを持ったため enum 化（PR #10 レビュー Low-2）:
    /// タイポや将来の呼び元追加で coalescing が黙って効かなくなる事故をコンパイル時に防ぐ。
    /// ログには `rawValue` を出す。`manualCoalesced` は coalesced ラウンドのログ専用（呼び元は渡さない）。
    enum PullReason: String, Sendable {
        case startup
        case poll
        case wake
        case networkUp = "network-up"
        case manual
        case manualCoalesced = "manual-coalesced"
    }

    /// リモート（S3）の変更をローカルに取り込む。
    /// - シャード etag キャッシュ (`shard_state`) で差分のみ処理
    /// - ローカル無しならダウンロード / SHA 衝突ならリネームしてからダウンロード
    /// - 変更があったシャードに属していたが remoteMap から消えたファイルは applyRemoteDeletion
    /// `reason` は契機ログ + coalescing 分岐用（既定 `.manual`）。**ゲート通過後にのみ**
    /// ログするので、並行で弾かれた契機を「triggered」と誤記録しない（PR #9 レビュー ⑥。
    /// 旧 `triggerRemotePullSafely` ラッパを本メソッドへ畳み込んで廃止した）。
    func triggerRemotePull(reason: PullReason = .manual) async {
        // 並行 pull を構造的に禁止する単一ゲート。start()（起動時）・メニューの「S3 から取得」・
        // poll / wake / network のすべてがこの公開メソッドを通るので、ここで排他すれば
        // 同一ファイルが複数の reconcile から同時にダウンロードされ、決定的 tmp
        // （dl-<sha(path)>.part）への並行追記で破損するのを防げる。
        // @MainActor なので check と set の間に await が無く、2 つの呼びが割り込まずに直列化される。
        if isRemotePulling {
            // 手動押下だけはドロップせず pending 化して、現 pull 終了後にもう 1 周する（coalescing・
            // PR #9 レビュー ④）。poll/wake/network は次の周期が必ず来るので従来どおりドロップで良い。
            if reason == .manual { pendingManualPull = true }
            return
        }
        isRemotePulling = true
        defer { isRemotePulling = false }
        var currentReason = reason
        repeat {
            pendingManualPull = false
            AppLogger.sync.info("Starting remote pull (\(currentReason.rawValue, privacy: .private))")
            do {
                try await performRemotePull()
                lastRemoteCheckedAt = Date()
            } catch {
                AppLogger.sync.error("Remote pull failed: \(String(describing: error), privacy: .private)")
                await recordIssue(SyncIssueClassifier.classify(error: error), logAs: "Remote pull failed")
            }
            currentReason = .manualCoalesced
            // stop()（pause / factory reset 経路）後や呼び元タスクの cancel 後に新ラウンドを
            // *開始* しない（PR #10 レビュー Low-1）。in-flight の 1 周は既存挙動どおり走り切る。
        } while pendingManualPull && running && !Task.isCancelled
    }

    private func performRemotePull() async throws {
        // Settings のダウンロード帯域上限を共有 limiter に反映（次の DL から効く）。
        await refreshBandwidthLimits()
        let reader = ManifestReader(s3: s3, db: db)
        guard let result = try await reader.read() else { return }
        let remoteMap = result.files
        let dl = Downloader(
            downloadClient: s3,
            db: db,
            syncRoot: syncRoot,
            tmpDir: tmpDir,
            deviceId: deviceId,
            transferStore: TransferStateStore(db: db),
            progressReporter: makeProgressReporter(),
            downloadLimiter: downloadLimiter
        )

        // 1) 取り込み（最大 5 並列）
        let entries = Array(remoteMap)
        await withTaskGroup(of: Void.self) { group in
            let limit = 5
            var inflight = 0
            for (path, entry) in entries {
                if inflight >= limit {
                    _ = await group.next()
                    inflight -= 1
                }
                group.addTask { [weak self] in
                    await self?.reconcileRemoteEntry(path: path, entry: entry, dl: dl)
                }
                inflight += 1
            }
            await group.waitForAll()
        }

        // 2) 削除反映: 変更があったシャードに属するファイルで、remoteMap に無いもの
        let affected = result.updatedShards.union(result.removedShards)
        if !affected.isEmpty {
            let dbPaths: [String] = try await db.pool.read { db in
                try FileRecord.fetchAll(db).map { $0.path }
            }
            for path in dbPaths where remoteMap[path] == nil {
                let sid = ManifestSharding.shardId(for: path)
                guard affected.contains(sid) else { continue }
                do {
                    _ = try await dl.applyRemoteDeletion(relativePath: path)
                } catch {
                    AppLogger.sync.error("applyRemoteDeletion(\(path, privacy: .private)) failed: \(String(describing: error), privacy: .private)")
                    await recordIssue(
                        SyncIssueClassifier.classify(error: error, path: path),
                        logAs: "Remote deletion failed"
                    )
                }
            }
        }

        // リモート由来の .syncignore 変更を反映（FSEvents 経由でも拾えるが初回 pull の保険）
        await reloadIgnoreMatcher()
        await refreshQueueDepth()
    }

    private func reconcileRemoteEntry(
        path: String,
        entry: ManifestFileEntry,
        dl: Downloader
    ) async {
        // C1: マニフェスト由来の path はここでも検証（Downloader 側でも検証するが UI 経由で扱う前に弾く）
        let fullURL: URL
        do {
            fullURL = try PathValidator.resolveSafely(relativePath: path, syncRoot: syncRoot)
        } catch {
            AppLogger.sync.error("Rejected unsafe remote path: \(path, privacy: .private)")
            // リモート由来の不正パスは UI / ログに流さない（現挙動維持）。path は意図的に nil。
            await recordIssue(
                SyncIssue(
                    id: UUID(), date: Date(), path: nil, category: .unsafePath,
                    rawDetail: "Unsafe remote path rejected (manifest)"
                ),
                logAs: "Unsafe remote path rejected (manifest)"
            )
            return
        }
        let localRec: FileRecord?
        do {
            localRec = try await db.pool.read { db in
                try FileRecord.fetchOne(db, key: path)
            }
        } catch {
            AppLogger.db.error("Remote pull DB read failed for \(path, privacy: .private): \(String(describing: error), privacy: .private)")
            return
        }

        // 除外判定: リモート新規（未追跡）が除外対象ならダウンロードしない。既存追跡は触らない。
        let tracked = (localRec?.lastSyncedAt != nil)
        if IgnoreDecision.shouldSkip(relativePath: path, isAlreadyTracked: tracked, matcher: ignoreMatcher) {
            AppLogger.sync.info("Skipping ignored remote entry: \(path, privacy: .private)")
            return
        }

        do {
            // ローカル状態。不在 / 存在するがハッシュ不能 / SHA 取得済み を区別して decide() へ渡す。
            let localState: LocalState
            if FileManager.default.fileExists(atPath: fullURL.path) {
                localState = (try? HashCalculator.sha256(of: fullURL)).map(LocalState.present) ?? .unreadable
            } else {
                localState = .absent
            }

            // 競合解決は ThreeWayMerge に一本化（remote はここでは常に非 nil）。
            switch ThreeWayMerge.decide(base: localRec?.sha256, local: localState, remote: entry.sha256) {
            case .download, .localMatchesRemote:
                // リモート採用（欠落/上書き）または内容一致（download() の早期 return で DB を最新化）。
                try await dl.download(relativePath: path, entry: entry)
            case .conflictThenDownload:
                // 双方乖離（ローカル編集 / 未追跡 / unreadable）→ ローカルをコンフリクトコピーへ退避してからリモート取得。
                let localCopy = try dl.renameLocalForConflict(relativePath: path)
                // 手動マージが要る可能性があるので通知（退避自体は成功＝download 失敗でも知らせる）。
                // fire-and-forget: 初回の許可プロンプト待ちで同期処理を止めない（PR #18 レビュー Medium）。
                Task { await self.notifier?.post(.conflictCopyCreated(path: path, localCopyPath: localCopy)) }
                try await dl.download(relativePath: path, entry: entry)
            case .deleteLocal, .keepLocalRemoteDeleted, .noop:
                // remote が非 nil のここでは到達しない。来たら decide() のロジックバグ。
                assertionFailure("unreachable: remote is non-nil in reconcileRemoteEntry")
            }
        } catch {
            AppLogger.sync.error("Remote reconcile \(path, privacy: .private) failed: \(String(describing: error), privacy: .private)")
            await recordIssue(
                SyncIssueClassifier.classify(error: error, path: path),
                logAs: "Remote reconcile failed"
            )
        }
    }

    // MARK: - Event handling

    private func handleDebounced(_ event: FileChangeEvent) async {
        do {
            try await processEventToQueue(event)
        } catch {
            AppLogger.sync.error("Failed to enqueue change for \(event.relativePath, privacy: .private): \(String(describing: error), privacy: .private)")
            await recordIssue(
                SyncIssueClassifier.classify(error: error, path: event.relativePath),
                logAs: "Failed to enqueue local change"
            )
        }
    }

    private func processEventToQueue(_ event: FileChangeEvent) async throws {
        let path = event.relativePath
        let now = Date().timeIntervalSince1970

        // .syncignore の変更/削除はルールを再読込し、フルスキャンで全体を再評価する。
        // .syncignore 自身は同期対象（Q2）なので、この後の通常処理（アップロード/削除）も継続する。
        if path == ".syncignore" {
            await reloadIgnoreMatcher()
            Task { [weak self] in await self?.triggerFullScan() }
        }

        switch event.kind {
        case .createdOrModified:
            let fullURL = syncRoot.appendingPathComponent(path)
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: fullURL.path)
            } catch {
                // file gone between event and now → treat as delete
                try await enqueueDelete(path: path, now: now)
                return
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = ((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970

            let existing = try await db.pool.read { db in
                try FileRecord.fetchOne(db, key: path)
            }
            // 変更判定はフルスキャンと同じ ChangeDetector（SHA ゲート込み）に集約。
            let known = existing.map {
                ChangeDetector.Known(
                    size: $0.size, mtime: $0.mtime,
                    sha256: $0.sha256, isSynced: $0.lastSyncedAt != nil
                )
            }
            switch ChangeDetector.preDecision(known: known, size: size, mtime: mtime) {
            case .skip:
                return  // unchanged
            case .enqueue:
                break
            case .verifyHash:
                // @MainActor なので hash は detached で（メインスレッドをブロックしない）。
                let knownSha = known?.sha256 ?? ""
                let computed = await Task.detached(priority: .utility) {
                    try? HashCalculator.sha256(of: fullURL)
                }.value
                switch ChangeDetector.postHash(knownSha: knownSha, computedSha: computed) {
                case .refreshMtimeOnly:
                    // mtime ドリフトのみ → CAS で修復してアップロードしない（performFullScan と同じ）。
                    try await db.refreshMtimeIfShaUnchanged(
                        path: path, expectedSha: knownSha, newMtime: mtime
                    )
                    return
                case .enqueue:
                    break
                }
            }

            // 除外判定（新規被マッチはスキップ。既存追跡・.syncignore 自身は通す）
            let tracked = (existing?.lastSyncedAt != nil)
            if IgnoreDecision.shouldSkip(relativePath: path, isAlreadyTracked: tracked, matcher: ignoreMatcher) {
                return
            }

            try await db.pool.write { db in
                var rec = UploadQueueRecord(
                    id: nil,
                    path: path,
                    operation: "upload",
                    enqueuedAt: now,
                    attempts: 0,
                    nextRetryAt: nil,
                    lastError: nil
                )
                try rec.insert(db, onConflict: .replace)
            }
            await refreshQueueDepth()

        case .deleted:
            // DB にいないなら無視
            let existing = try await db.pool.read { db in
                try FileRecord.fetchOne(db, key: path)
            }
            guard existing != nil else { return }
            try await enqueueDelete(path: path, now: now)
        }
    }

    private func enqueueDelete(path: String, now: Double) async throws {
        try await db.pool.write { db in
            var rec = UploadQueueRecord(
                id: nil,
                path: path,
                operation: "delete",
                enqueuedAt: now,
                attempts: 0,
                nextRetryAt: nil,
                lastError: nil
            )
            try rec.insert(db, onConflict: .replace)
        }
        await refreshQueueDepth()
    }

    // MARK: - Bandwidth (サブ E)

    /// Settings の帯域上限（bytes/sec、`<= 0` = 無制限）を共有 limiter に反映する。
    /// `uploadSizeLimitBytes` と同じく config を読み直す流儀で、転送周回の冒頭から呼ぶ。
    private func refreshBandwidthLimits() async {
        await uploadLimiter.setRate(Double(config.uploadBandwidthBytesPerSec))
        await downloadLimiter.setRate(Double(config.downloadBandwidthBytesPerSec))
    }

    // MARK: - Queue processing loop

    private func runQueueLoop() async {
        let uploader = Uploader(
            s3: s3, db: db, syncRoot: syncRoot, deviceId: deviceId, config: config,
            transferStore: TransferStateStore(db: db),
            progressReporter: makeProgressReporter(),
            uploadLimiter: uploadLimiter
        )
        while !Task.isCancelled {
            if paused {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            // Settings の帯域上限を共有 limiter に反映（uploader が保持する参照に効く）。
            await refreshBandwidthLimits()
            let items: [UploadQueueRecord]
            do {
                items = try await fetchReadyItems()
            } catch {
                AppLogger.db.error("Queue fetch failed: \(String(describing: error), privacy: .private)")
                try? await Task.sleep(for: .seconds(3))
                continue
            }

            if items.isEmpty {
                status = .idle
                await pruneUnstableWarned()
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            status = .syncing(SyncProgress(
                totalBytes: 0, transferredBytes: 0,
                currentFile: items.first?.path, queueDepth: items.count
            ))

            await withTaskGroup(of: Void.self) { group in
                let limit = 5
                var inFlight = 0
                for item in items {
                    if inFlight >= limit {
                        _ = await group.next()
                        inFlight -= 1
                    }
                    let local = uploader
                    group.addTask { [weak self] in
                        await self?.processOne(item, uploader: local)
                    }
                    inFlight += 1
                }
                await group.waitForAll()
            }
            await refreshQueueDepth()
            lastSyncedAt = Date()
        }
    }

    private nonisolated func processOne(_ item: UploadQueueRecord, uploader: Uploader) async {
        do {
            try await uploader.process(item)
        } catch {
            AppLogger.sync.error("Upload/delete failed for \(item.path, privacy: .private): \(String(describing: error), privacy: .private)")
            await self.handleProcessingFailure(item: item, error: error)
        }
    }

    private func handleProcessingFailure(item: UploadQueueRecord, error: Error) async {
        // L6 (A-detect): 読込中にファイルが変化していた＝torn を避けてコミットを見送った。これは「エラー」では
        // なく「まだ安定していない」なので、give-up カウント（attempts）に載せず安定するまで延期する
        // （恒久的に未バックアップにしない）。延期しても安定しない場合は別途ユーザに可視化する。
        if case SyncError.fileChangedDuringUpload = error {
            await handleUnstableFile(item: item)
            return
        }

        // サイズ上限超過は恒久的失敗（リトライしても無駄）。黙ってスキップせず、分類サマリ
        // （fileTooLarge + guidance）として recentIssues に出す（一級 UX 状態として扱う）。
        if case SyncError.fileTooLarge = error {
            // sync_log は下の Tx 内でキュー除去と原子的に書く（logAs: nil）。
            await recordIssue(SyncIssueClassifier.classify(error: error, path: item.path))
            // 恒久的に未バックアップ＝サイレントな取りこぼしにしないよう通知する。
            // fire-and-forget: 初回プロンプト待ちが直後のキュー除去 Tx を遅らせない（PR #18 レビュー Medium）。
            Task { await self.notifier?.post(.fileTooLarge(path: item.path)) }
            do {
                try await db.pool.write { db in
                    // L6: 処理したこの行 (item.id) だけを消す（path 基準だと処理中に置換された新 id 行を巻き込む）。
                    try UploadQueueRecord
                        .filter(Column("id") == item.id)
                        .deleteAll(db)
                    var log = SyncLogRecord(
                        id: nil,
                        timestamp: Date().timeIntervalSince1970,
                        eventType: SyncLogEventType.error.rawValue,
                        path: item.path,
                        message: "Exceeds the per-file upload size limit; not backed up. Adjust the limit in Settings.",
                        details: String(describing: error)
                    )
                    try log.insert(db)
                }
                return
            } catch {
                // 削除に失敗したら即 return せず通常バックオフへフォールスルーする。
                // さもないと行が残ったまま nextRetryAt も更新されず、次周回で即再処理＝busy-loop になる。
                AppLogger.db.error("Failed to record size-limit skip: \(String(describing: error), privacy: .private)")
            }
        } else {
            // リトライごとの sync_log 書込はしない（5 回で give-up 時に下で 1 回だけ記録）。
            await recordIssue(SyncIssueClassifier.classify(error: error, path: item.path))
        }

        let attempts = item.attempts + 1
        let now = Date().timeIntervalSince1970

        if attempts >= 5 {
            do {
                try await db.pool.write { db in
                    // L6: 処理したこの行 (item.id) だけを消す（path 基準だと処理中に置換された新 id 行を巻き込む）。
                    try UploadQueueRecord
                        .filter(Column("id") == item.id)
                        .deleteAll(db)
                    var log = SyncLogRecord(
                        id: nil,
                        timestamp: now,
                        eventType: SyncLogEventType.error.rawValue,
                        path: item.path,
                        // 生エラーは message に埋め込まず details へ（message は固定文・F4 と同じ整理）。
                        message: "Gave up after \(attempts) attempts",
                        details: String(describing: error)
                    )
                    try log.insert(db)
                }
            } catch {
                AppLogger.db.error("Failed to record give-up: \(String(describing: error), privacy: .private)")
            }
            // リトライを使い切って未バックアップのまま諦めた＝通知する（fire-and-forget・PR #18 レビュー Medium）。
            Task { await self.notifier?.post(.uploadGaveUp(path: item.path)) }
            return
        }

        let delay = Self.backoffDelay(attempts: attempts)
        let nextRetry = now + delay

        do {
            try await db.pool.write { db in
                // L6: この行 (item.id) のリトライ状態だけを更新する。処理中に同 path へ新イベントが
                // 届いて INSERT OR REPLACE で新 id 行に置換されていれば、ここは fetch で nil → no-op となり、
                // 新行（attempts=0・即 ready）が次周回でそのまま処理される（古い失敗のバックオフを被せない）。
                if var existing = try UploadQueueRecord
                    .filter(Column("id") == item.id)
                    .fetchOne(db) {
                    existing.attempts = attempts
                    existing.nextRetryAt = nextRetry
                    existing.lastError = String(describing: error)
                    try existing.update(db)
                }
            }
        } catch {
            AppLogger.db.error("Failed to update retry state: \(String(describing: error), privacy: .private)")
        }
    }

    /// 読込中に変化し続けるファイル（L6 A-detect の不安定）を、安定するまで延期する。
    /// attempts は触らない（give-up に載せない＝恒久的に未バックアップにしない）。再検査間隔は保留経過に
    /// 比例して伸ばし、巨大ファイルの無駄な全読みを抑える（最小 unstableQuiescenceSeconds・上限 300s）。
    /// 一定時間安定しなければ「まだバックアップされていない」を 1 回だけユーザに見せる（dedup）。
    private func handleUnstableFile(item: UploadQueueRecord) async {
        let now = Date().timeIntervalSince1970
        let pendingAge = max(0, now - item.enqueuedAt)
        let nextRetry = now + Self.unstableRetryDelay(pendingAge: pendingAge)

        do {
            // deferUnstableQueueItem は attempts/enqueuedAt を保持し nextRetryAt だけ前進させる。
            // 処理中に置換された新 id 行があれば no-op（新行が次周回で処理される）。
            _ = try await db.deferUnstableQueueItem(
                id: item.id, nextRetryAt: nextRetry,
                lastError: "File changed during upload; deferring until it settles"
            )
        } catch {
            AppLogger.db.error("Failed to defer unstable item: \(String(describing: error), privacy: .private)")
        }

        // 可視化: 安定しないまま閾値を超えたら 1 回だけ「未バックアップ」を見せる（retry ごとの重複は出さない）。
        if Self.shouldWarnUnstable(pendingAge: pendingAge), !unstableWarned.contains(item.path) {
            unstableWarned.insert(item.path)
            // sync_log はこの直後に info で書く（logAs: nil）。
            await recordIssue(
                SyncIssue(
                    id: UUID(), date: Date(), path: item.path, category: .unstableFile,
                    rawDetail: "File keeps changing during upload; deferring until it settles (not backed up yet)."
                )
            )
            do {
                try await db.pool.write { db in
                    var log = SyncLogRecord(
                        id: nil,
                        timestamp: now,
                        eventType: SyncLogEventType.info.rawValue,
                        path: item.path,
                        message: "File keeps changing during upload; deferring until it settles (not backed up yet).",
                        details: nil
                    )
                    try log.insert(db)
                }
            } catch {
                AppLogger.db.error("Failed to record unstable-defer log: \(String(describing: error), privacy: .private)")
            }
            // unstableWarned で dedup 済み＝この path につき 1 回だけ通知する（fire-and-forget・PR #18 レビュー Medium）。
            Task { await self.notifier?.post(.fileKeepsChanging(path: item.path)) }
        }
    }

    /// キューから消えた（安定して同期完了 or 除去された）path を unstableWarned から間引く。
    /// これで同じ path が後で再び不安定化したとき、また 1 回だけ「未バックアップ」を見せられる。
    /// アイドル周回で呼ぶ（このとき残るのは延期中の不安定行だけなので intersection が安全）。
    private func pruneUnstableWarned() async {
        guard !unstableWarned.isEmpty else { return }
        do {
            let queued = try await db.pool.read { db in
                Set(try UploadQueueRecord.fetchAll(db).map(\.path))
            }
            unstableWarned.formIntersection(queued)
        } catch {
            // 間引き失敗は致命的でない（次のアイドル周回で再試行）。
        }
    }

    /// 不安定ファイル（L6 A-detect の延期）の再検査間隔（秒）。**保留経過 `pendingAge` に比例**させ、
    /// 最小 `unstableQuiescenceSeconds`（書込が落ち着く最短待ち）・上限 300s でクランプする。give-up カウント
    /// （`attempts`）には載せないので、`backoffDelay` と違い attempts ではなく pendingAge を基準にする。
    /// 比例設計のため pendingAge は ~ 3,6,12,24,48… と倍々に増え、初回警告（30s 閾値超え）は実際 ~48s 付近。
    nonisolated static func unstableRetryDelay(pendingAge: TimeInterval) -> TimeInterval {
        min(max(unstableQuiescenceSeconds, pendingAge), 300)
    }

    /// 不安定のまま保留がこの閾値を超えたら「まだバックアップされていない」を 1 回だけユーザに見せる。
    nonisolated static func shouldWarnUnstable(pendingAge: TimeInterval) -> Bool {
        pendingAge >= unstableWarnThresholdSeconds
    }

    static func backoffDelay(attempts: Int) -> TimeInterval {
        let base = pow(2.0, Double(attempts))
        let jitter = Double.random(in: 0.75...1.25)
        return min(base * jitter, 300)
    }

    private func fetchReadyItems() async throws -> [UploadQueueRecord] {
        let now = Date().timeIntervalSince1970
        return try await db.pool.read { db in
            try UploadQueueRecord
                .filter(Column("attempts") < 5)
                .filter(Column("next_retry_at") == nil || Column("next_retry_at") <= now)
                .order(Column("enqueued_at"))
                .limit(20)
                .fetchAll(db)
        }
    }

    private func refreshQueueDepth() async {
        do {
            let count = try await db.pool.read { db in
                try UploadQueueRecord.fetchCount(db)
            }
            self.queueDepth = count
        } catch {
            // ignore
        }
    }

    /// 分類済み issue を recentIssues に積む（上限 50・FIFO）。`logAs` に英語固定文を渡すと
    /// sync_log("error") にも 1 行残す（message = 固定文、details = rawDetail）。nil は
    /// 呼び元が自前の write Tx 内で原子的に書く箇所（fileTooLarge / give-up / 不安定警告）か、
    /// リトライごとの重複記録を避けたい箇所（give-up 前の各失敗）。
    private func recordIssue(_ issue: SyncIssue, logAs logMessage: String? = nil) async {
        recentIssues.append(issue)
        if recentIssues.count > 50 { recentIssues.removeFirst(recentIssues.count - 50) }
        guard let logMessage else { return }
        do {
            try await db.appendLog(
                type: .error, path: issue.path, message: logMessage, details: issue.rawDetail
            )
        } catch {
            AppLogger.db.error("Failed to append issue log: \(String(describing: error), privacy: .private)")
        }
    }

    /// メニューバーの「Clear」用。
    func clearIssues() {
        recentIssues.removeAll()
    }
}

/// NWPathMonitor のクロージャから @MainActor へ値を渡すための単純なロック付きホルダ。
private final class LastSatisfiedHolder: @unchecked Sendable {
    private var value: Bool = false
    private let lock = NSLock()
    func swap(_ new: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let prev = value
        value = new
        return prev
    }
}
