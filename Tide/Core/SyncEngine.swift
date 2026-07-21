import TideCore
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

    /// 現在有効な `.syncignore` のパターン（Settings 表示用）。ネスト対応でディレクトリ単位にグルーピング。
    var activeIgnorePatterns: [LayeredSyncIgnore.DirectoryGroup] = []

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
    /// pull と restore を直列化する単一ゲート（#34 / D5）。pull は `tryAcquire`（busy ならドロップ/pending）、
    /// restore は `acquire`（待機）で取得する。`isRemotePulling` は UI 表示専用に残す（pull 中のみ true）。
    @ObservationIgnored private let remoteOpGate = RemoteOpGate()
    private var paused: Bool = false
    private var running: Bool = false
    private var ignoreMatcher: LayeredSyncIgnore = .empty
    /// 直近 pull が観測したリモート全 path（Issue #69）。event `.deleted` で FileRecord 不在
    /// （再セットアップ直後の採用未了）の削除がリモート追跡分かを S3 往復なしで照会する。
    /// 更新はシャード単位のマージ（`performRemotePull`）: 変化/削除シャード分だけ差し替え、
    /// 無変化シャード分は前回値を温存する。丸ごと差し替えると 2 回目以降の pull で
    /// ManifestReader が無変化シャードを FileRecord から再合成（＝採用済みサブセットのみ）するため
    /// 未採用 path が脱落し、採用未了ウィンドウが再び開く。非永続（再起動直後は空 = 既知の残余）。
    @ObservationIgnored private var remoteKnownPaths: Set<String> = []
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
            // .syncignore の初期ロードはフルスキャンへ畳み込み済み（#64: 走査副産物として層辞書を
            // 構築し scan 完了時に publish する。先行 discovery 走査＝ツリー二重走査はしない）。
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

    /// pull / アップロード競合解決で使う `Downloader` を同一構成で生成する。
    private func makeDownloader() -> Downloader {
        Downloader(
            downloadClient: s3,
            db: db,
            syncRoot: syncRoot,
            tmpDir: tmpDir,
            deviceId: deviceId,
            transferStore: TransferStateStore(db: db),
            progressReporter: makeProgressReporter(),
            downloadLimiter: downloadLimiter
        )
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

    /// matcher 世代カウンタ（#64）: scan 完了時 publish の stale ガード。走査中にイベント patch /
    /// pull reload が matcher を進めていたら、走査開始時点の世代で作った副産物辞書は publish しない
    /// （patch 側は triggerFullScan を coalesce しているので、続く scan が新世代の完全な辞書を
    /// publish する。pull reload は自身が完全な辞書を publish 済み）。
    private var ignoreGeneration = 0

    /// テスト用の現在世代の読み出し（`publishScanIgnoreMatcher` の世代ガード配線を直接駆動する）。
    var currentIgnoreGeneration: Int { ignoreGeneration }

    /// 層状マッチャと Settings 表示用パターンを更新する唯一の書込点（世代も進める）。
    private func publishIgnoreMatcher(_ matcher: LayeredSyncIgnore) {
        ignoreGeneration += 1
        ignoreMatcher = matcher
        activeIgnorePatterns = matcher.directoryGroups
    }

    /// 再構築済み層辞書の publish（世代ガード付き・#64）。走査 / リロード開始時点から世代が
    /// 進んでいたら stale として捨て false を返す（scan 経路は patch 側が coalesce した次の scan が
    /// 回収・pull reload 経路は呼び元がフルスキャンへフォールバックする。PR #74 レビュー低 4）。
    @discardableResult
    func publishRebuiltIgnoreMatcher(_ matcher: LayeredSyncIgnore, ifGenerationStillEquals generation: Int) -> Bool {
        guard generation == ignoreGeneration else {
            AppLogger.sync.info("Skipped stale ignore-matcher publish (concurrent .syncignore update)")
            return false
        }
        publishIgnoreMatcher(matcher)
        return true
    }

    /// FSEvents で届いた 1 枚の `.syncignore` 変更を、ツリー走査なしで層差し替えする（#64）。
    /// 全体再構築は後続 `triggerFullScan` の走査副産物 publish が担い、ここは「保存直後〜scan 完了
    /// までの後続イベントが旧 matcher で評価される窓」を閉じるためのインプレース patch
    /// （例: ビルド実行中に `build/` を `.syncignore` へ追記 → 窓中の生成物イベントが upload され
    /// 恒久追跡化する事故を防ぐ。除外は未追跡ファイル限定なので一度追跡されると外れない）。
    func patchIgnoreLayer(forSyncignoreAt relativePath: String) async {
        // 機密網配下の `.syncignore` は読まない（loadLayeredIgnore / 走査と同じゲート）。
        guard !HardcodedIgnoreRules.shouldIgnore(relativePath: relativePath) else { return }
        let root = syncRoot
        let dir = (relativePath as NSString).deletingLastPathComponent
        let layer = await Task.detached(priority: .utility) {
            Self.readSyncignoreLayer(relativePath: relativePath, syncRoot: root)
        }.value
        // 新規層の追加が maxFiles を超えるなら見送る（防御的上限は走査側と共通。既存層の
        // 更新 / 除去は常に通す）。
        if layer != nil, !ignoreMatcher.hasLayer(directory: dir),
           ignoreMatcher.fileCount >= LayeredSyncIgnore.maxFiles {
            AppLogger.sync.error("Too many .syncignore files (>\(LayeredSyncIgnore.maxFiles)); patch skipped")
            return
        }
        publishIgnoreMatcher(ignoreMatcher.updatingLayer(directory: dir, matcher: layer))
        AppLogger.sync.info("Patched .syncignore layer: \(dir.isEmpty ? "(root)" : dir, privacy: .private)")
    }

    /// 同期ルート配下の全 `.syncignore`（ルート + ネスト）を読み直して層状マッチャと
    /// Settings 表示用パターンを更新する。#64 以降、起動時とローカル `.syncignore` 変更時は
    /// フルスキャンの走査副産物 + インプレース patch に畳まれたため、discovery 走査の呼び元は
    /// pull 末尾（リモート由来 `.syncignore` 変化時）のみ。
    func reloadIgnoreMatcher() async {
        let generationAtStart = ignoreGeneration
        let matcher = await Self.loadLayeredIgnore(syncRoot: syncRoot)
        // 走査中にイベント patch が挟まっていたら（世代前進）、walk 開始前の内容を含む辞書で
        // patch 済みの層を巻き戻さない。publish せずフルスキャンへフォールバックし、その走査
        // フェーズの副産物が新世代の完全な辞書を publish して収束する（PR #74 レビュー低 4:
        // 無条件 publish だと stale 層が残留し、世代ガードが訂正 scan の副産物まで捨てていた）。
        guard publishRebuiltIgnoreMatcher(matcher, ifGenerationStillEquals: generationAtStart) else {
            Task { [weak self] in await self?.triggerFullScan() }
            return
        }
        AppLogger.sync.info("Reloaded .syncignore: \(matcher.fileCount) file(s)")
    }

    /// 同期ルート配下の全 `.syncignore` を安全に収集して層状マッチャ（`LayeredSyncIgnore`）を構築する。
    /// 各ファイルは symlink 非追従 / `PathValidator` で root エスケープ拒否 / 256KB 上限。
    /// 機密網ディレクトリ（`.tide` / `.aws` 等）と symlink ディレクトリは丸ごとスキップ（配下を走査しない）。
    /// `.syncignore` 数は `LayeredSyncIgnore.maxFiles` で防御的に有界化する。
    /// #64 以降の用途はリモート由来の変化検知（pull 末尾の `reloadIgnoreMatcher`）専用。
    /// 起動時・ローカル変更時の再構築はフルスキャンの走査副産物（`singlePassScan`）が担う。
    private static func loadLayeredIgnore(syncRoot: URL) async -> LayeredSyncIgnore {
        await Task.detached(priority: .utility) { () -> LayeredSyncIgnore in
            let fm = FileManager.default
            guard let walker = fm.enumerator(
                at: syncRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else { return .empty }

            var matchers: [String: SyncIgnoreMatcher] = [:]
            while let url = walker.nextObject() as? URL {
                if matchers.count >= LayeredSyncIgnore.maxFiles {
                    AppLogger.sync.error("Too many .syncignore files (>\(LayeredSyncIgnore.maxFiles)); ignoring the rest")
                    break
                }
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                ) else { continue }

                // セキュリティゲート: シンボリックリンクは絶対に追従しない。deep enumeration は
                // symlink（ディレクトリリンク含む）へそもそも再帰しないため continue だけで足りる。
                // ここで skipDescendants() を呼んではならない（Issue #54）: 現在 item がファイル
                // （symlink）のとき呼ぶと**無関係な隣接ディレクトリ**への再帰がスキップされ、配下の
                // .syncignore が層状マッチャから欠落する（下の機密網 dir スキップのように「現在 item が
                // ディレクトリ」の文脈でのみ正しく働く API）。
                if values.isSymbolicLink == true {
                    continue
                }

                let relative = Self.relativePath(of: url, root: syncRoot)
                if values.isDirectory == true {
                    // 機密網ディレクトリ（.tide / .aws / .ssh …）は丸ごとスキップ。配下の .syncignore も読まない
                    // （配下のファイルは常にハードコード除外され、適用余地が無い）。
                    if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, url.lastPathComponent == ".syncignore" else { continue }
                // 機密網配下の .syncignore（ディレクトリ判定をすり抜けた場合の保険）は読まない。
                if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }

                // 安全読込: PathValidator で root エスケープ拒否 + symlink 再確認 + サイズ上限。
                guard let safeURL = try? PathValidator.resolveSafely(relativePath: relative, syncRoot: syncRoot),
                      !PathValidator.isSymbolicLink(at: safeURL),
                      let data = try? Data(contentsOf: safeURL),
                      data.count <= SyncIgnoreMatcher.maxBytes else { continue }

                let text = String(decoding: data, as: UTF8.self)
                // dir 相対パス（".syncignore" を落とす）。ルート直下は ""。
                let dir = (relative as NSString).deletingLastPathComponent
                matchers[dir] = SyncIgnoreMatcher.parse(text)
            }
            return LayeredSyncIgnore(matchers: matchers)
        }.value
    }

    /// SHA-256 計算を detached（off-main・.utility）で実行する共通ヘルパ。
    /// @MainActor のメソッドから呼んでもメインスレッドをブロックしない（pull / event 両経路で共用）。
    /// nonisolated: actor 状態を一切触らないので、reconcile の nonisolated static 本体（#30 / D1）から
    /// MainActor ホップなしで呼べる（`statSizeAndMtime` と同じ扱い）。既存の @MainActor 呼び元にも影響なし。
    nonisolated private static func computeHashDetached(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            // #31 / D2: scan/event の SHA ゲートと reconcile の localState 判定はこの 1 箇所を通る。
            // O_NOFOLLOW でリンク先を読まない（symlink なら nil → scan/event は enqueue・reconcile は
            // unreadable の安全側へ倒れる）。
            try? HashCalculator.sha256NoFollow(of: url)
        }.value
    }

    // MARK: - Full scan

    /// フルスキャン実行中フラグ + 実行中に届いた再要求の pending（PR #53 レビュー #7）。
    /// @MainActor なので check-and-set は割り込まれない。
    private var isFullScanning = false
    private var pendingFullScan = false

    func triggerFullScan() async {
        // 多重フルスキャンの抑止（PR #53 レビュー #7）: 実行中の再要求は pending に coalesce し、
        // 現行スキャンの完了後に 1 周だけ追加で走らせる（要求時点の新しい状態を取りこぼさない。
        // 種別変化イベントの連続着火や .syncignore 連続編集で detached ツリー走査が並走しない）。
        if isFullScanning {
            pendingFullScan = true
            return
        }
        isFullScanning = true
        defer { isFullScanning = false }
        repeat {
            pendingFullScan = false
            AppLogger.sync.info("Starting full scan: \(self.syncRoot.path, privacy: .private)")
            do {
                try await performFullScan()
            } catch {
                AppLogger.sync.error("Full scan failed: \(String(describing: error), privacy: .private)")
                await recordIssue(SyncIssueClassifier.classify(error: error), logAs: "Full scan failed")
            }
        } while pendingFullScan
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
        // pull と同一ゲートで直列化（#34 / D5）: in-flight pull / 先行 restore の完了を待ってから書き戻す。
        // これで復元の atomic move（remove → move）と pull の reconcile / 削除反映が同一 path に同時に
        // 触れる窓を構造的に閉じる。重い DL〜move は RestoreService 内で off-main に走る。
        await remoteOpGate.acquire()
        do {
            let result = try await service.restore(relativePath: relativePath, versionId: versionId)
            remoteOpGate.release()
            // 復元中に押された手動 Pull を消化（成功/失敗どちらの経路でも対称に＝下記 catch と同様）。
            await drainPendingManualPull()
            // 書き戻したファイルを拾わせる（FileWatcher の取りこぼし保険＝確実に再アップロードへ乗せる）。
            // フルスキャンは成功時のみ（復元できなかったファイルを上げ直す必要は無い）。
            await triggerFullScan()
            return result
        } catch {
            // 復元が失敗しても、その間に押された手動 Pull は独立した意図なので落とさず消化する
            // （pull 経路の repeat-while-pending が失敗時もセルフ drain するのと対称）。
            remoteOpGate.release()
            await drainPendingManualPull()
            throw error
        }
    }

    /// 復元中に手動「Pull from S3」が押されていた場合（ゲート busy で `pendingManualPull` が立つ）に
    /// 1 周消化する＝ pull 進行中押下の coalescing（PR #9 ④）を restore 経路へ拡張する（#34 / D5）。
    /// ゲート解放直後に呼ぶ前提。`triggerRemotePull` は `guard remoteOpGate.tryAcquire()` まで await を
    /// 挟まないので、**先行する待機 restore が無ければ**ゲートは空いていて取得・実行される。待機 restore が
    /// いる場合は `release()` が所有権をそれへ引き渡す（`locked` は true のまま）ため tryAcquire は失敗して
    /// 再 pending 化されるが、所有権を受け取った restore が完了時に再度ここを通るので取りこぼしは無い。
    private func drainPendingManualPull() async {
        if pendingManualPull {
            await triggerRemotePull(reason: .manual)
        }
    }

    private func performFullScan() async throws {
        let root = self.syncRoot
        let db = self.db
        let now = Date().timeIntervalSince1970
        // #64 世代ガード: 走査中にイベント patch / pull reload が matcher を進めたら、この走査の
        // 副産物辞書は publish しない（publishRebuiltIgnoreMatcher のコメント参照）。
        let generationAtStart = ignoreGeneration

        // 走査本体は SyncEngine+FullScan.swift（#64: 再帰下降で `.syncignore` 層辞書も同時構築＝
        // 起動時 / `.syncignore` 変更時の discovery 走査を畳み込み、ツリー走査を 1 回にする）。
        // フェーズ 1: FS 走査のみ（stat + 層辞書 + 対象収集・DB 非接触）。
        let walk = try await Task.detached(priority: .utility) {
            try Self.walkSyncTree(root: root)
        }.value

        // 層辞書は分類フェーズ（per-file DB read / 変更時 hash を含む＝大きなツリーでは分オーダー）を
        // 待たずに publish する。起動時の先行 reloadIgnoreMatcher() 撤去で「matcher 空のまま event が
        // 評価される窓」が scan 完了時間まで拡大するのを、旧 discovery 走査相当へ戻す（レビュー中 3）。
        publishRebuiltIgnoreMatcher(walk.ignoreMatcher, ifGenerationStillEquals: generationAtStart)

        // 列挙不能 dir を skip した走査は可視化する（削除検出は分類フェーズが抑止・レビュー高 2）。
        if walk.scanIncomplete {
            await recordIssue(
                SyncIssue(
                    id: UUID(), date: Date(), path: walk.unreadableDirs.first,
                    category: .localIO,
                    rawDetail: "Scan skipped unreadable directories: \(walk.unreadableDirs.joined(separator: ", ")). "
                        + "Deletion detection is suppressed until all directories are readable."
                ),
                logAs: "Scan skipped unreadable directories"
            )
        }

        // フェーズ 2: 分類 + enqueue（削除 → upload）。
        let result = try await Task.detached(priority: .utility) {
            try await Self.classifyAndEnqueue(walk: walk, db: db, now: now)
        }.value

        AppLogger.sync.info("Full scan: enqueued \(result.newEnqueued) uploads, \(result.deletedEnqueued) deletes, repaired \(result.mtimesRepaired) mtimes (\(result.ignoreMatcher.fileCount) .syncignore layer(s))")
        await refreshQueueDepth()
    }

    /// scan / event 共通の per-file 変更判定 → mtime 修復（CAS）。判定 → 実 I/O の配線を結合テスト可能に
    /// するため切り出した（#30 / D1）。アップロードの実 enqueue（onConflict が scan=.ignore /
    /// event=.replace で異なる）・除外判定・foundPaths 簿記は呼び元に残す。
    /// hash は `computeHashDetached` で off-main 実行するので @MainActor の event 経路からも安全に呼べる。
    enum FileSyncDecision: Equatable, Sendable {
        case skip            // size/mtime 一致 → 変更なし
        case enqueue         // 要アップロード
        case mtimeRepaired   // mtime ドリフトのみ → CAS で DB mtime を修復した
        case mtimeCASNoop    // refreshMtimeOnly だが CAS が並行更新で no-op（mtime を巻き戻さない）
    }

    nonisolated static func classifyLocalChange(
        existing: FileRecord?,
        fileURL: URL,
        size: Int64,
        mtime: Double,
        relativePath: String,
        db: LocalDatabase
    ) async throws -> FileSyncDecision {
        let known = existing.map {
            ChangeDetector.Known(
                size: $0.size, mtime: $0.mtime,
                sha256: $0.sha256, isSynced: $0.lastSyncedAt != nil
            )
        }
        switch ChangeDetector.preDecision(known: known, size: size, mtime: mtime) {
        case .skip:
            return .skip
        case .enqueue:
            return .enqueue
        case .verifyHash:
            // verifyHash は known 非 nil のときのみ返る（空 sha フォールバックは常に enqueue 側）。
            let knownSha = known?.sha256 ?? ""
            let computed = await Self.computeHashDetached(fileURL)
            switch ChangeDetector.postHash(knownSha: knownSha, computedSha: computed) {
            case .refreshMtimeOnly:
                // CAS: 判定〜書込の間に並行 pull が同 path を更新していたら no-op
                // （新しい sha / s3VersionId / s3Etag を巻き戻さない）。
                let repaired = try await db.refreshMtimeIfShaUnchanged(
                    path: relativePath, expectedSha: knownSha, newMtime: mtime
                )
                return repaired ? .mtimeRepaired : .mtimeCASNoop
            case .enqueue:
                return .enqueue
            }
        }
    }

    /// アップロードキューへ 1 行投入する。onConflict は scan=.ignore（attempts 保持）/
    /// event=.replace（処理中の同 path を置換）で呼び元が決める（#30 / D1 で配線テスト）。
    nonisolated static func enqueueUpload(
        db: LocalDatabase, path: String, now: Double, onConflict: Database.ConflictResolution
    ) async throws {
        try await db.pool.write { db in
            var rec = UploadQueueRecord(
                id: nil, path: path, operation: "upload",
                enqueuedAt: now, attempts: 0, nextRetryAt: nil, lastError: nil
            )
            try rec.insert(db, onConflict: onConflict)
        }
    }

    /// DB にあって実体走査で見つからなかった path を delete キューへ投入する（フルスキャンの削除検出）。
    /// - Returns: enqueue した削除件数。
    nonisolated static func enqueueScanDeletions(
        db: LocalDatabase, foundPaths: Set<String>, now: Double
    ) async throws -> Int {
        let knownPaths: Set<String> = try await db.pool.read { db in
            Set(try FileRecord.fetchAll(db).map { $0.path })
        }
        let missing = knownPaths.subtracting(foundPaths)
        guard !missing.isEmpty else { return 0 }
        try await db.pool.write { db in
            for p in missing {
                var rec = UploadQueueRecord(
                    id: nil, path: p, operation: "delete",
                    enqueuedAt: now, attempts: 0, nextRetryAt: nil, lastError: nil
                )
                try rec.insert(db, onConflict: .ignore)
            }
        }
        return missing.count
    }

    nonisolated static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(rootPath + "/") {
            return String(p.dropFirst(rootPath.count + 1))
        }
        return p
    }

    /// ローカルファイルの (size, mtime) を一度の stat で取得（reconcile の stat ゲート用）。
    /// scan の `.contentModificationDateKey` と同じ API 系。ディレクトリ / stat 不能なら nil。
    nonisolated static func statSizeAndMtime(at url: URL) -> (size: Int64, mtime: Double)? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize,
              let mtime = v.contentModificationDate?.timeIntervalSince1970
        else { return nil }
        return (Int64(size), mtime)
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
        // 並行 pull を構造的に禁止する単一ゲート（restore とも共有＝#34 / D5）。start()（起動時）・
        // メニューの「S3 から取得」・poll / wake / network のすべてがこの公開メソッドを通るので、ここで
        // 排他すれば同一ファイルが複数の reconcile から同時にダウンロードされ、決定的 tmp
        // （dl-<sha(path)>.part）への並行追記で破損するのを防げる。restore（acquire 保持中）とも排他され、
        // 復元の atomic move と pull の reconcile / 削除反映が同一 path に同時に触れる窓も閉じる。
        // @MainActor なので tryAcquire は同期 ＝ check と set の間に await が無く割り込まずに直列化される。
        guard remoteOpGate.tryAcquire() else {
            // 手動押下だけはドロップせず pending 化して、現 pull / restore 終了後にもう 1 周する
            // （coalescing・PR #9 レビュー ④）。poll/wake/network は次の周期が必ず来るので従来どおりドロップ。
            // restore 保持中の pending は restore 完了側で drain する（#34）。
            if reason == .manual { pendingManualPull = true }
            return
        }
        isRemotePulling = true
        defer {
            isRemotePulling = false
            remoteOpGate.release()
        }
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
        let affected = result.updatedShards.union(result.removedShards)
        // Issue #69: リモート既知 path 集合をシャード単位でマージ（規則は mergedRemoteKnownPaths 参照）。
        // **フェーズ 2（applyRemoteDeletion）より前に置くのが load-bearing**（PR #71 レビュー確認事項）:
        // pull 自身が適用したリモート削除の FSEvents エコー（`.deleted`）が届く時点で、該当 path は
        // 「affected シャードで除外済み ∧ remoteMap 不掲載」＝集合から脱落済みになり、削除を
        // リモートへ打ち返さない。
        remoteKnownPaths = Self.mergedRemoteKnownPaths(
            previous: remoteKnownPaths, affectedShards: affected, freshPaths: remoteMap.keys
        )
        let dl = makeDownloader()

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

        // 2) 削除反映: 変更があったシャード（affected・上で算出済み）に属するファイルで、remoteMap に無いもの
        // 今回の pull で .syncignore（ルート/ネスト）が変化したか。変化時のみ層状マッチャを再構築し、
        // 定常 pull でのツリー再走査を避ける（「変更時フル再構築」戦略・docs/08）。
        // 過大近似: shard が変化 ∧ path が .syncignore なら（reconcile が no-op でも）再構築する＝取りこぼし防止。
        var syncignoreTouched = false
        if !affected.isEmpty {
            for path in remoteMap.keys
            where IgnoreDecision.isSyncignoreFile(path) && affected.contains(ManifestSharding.shardId(for: path)) {
                syncignoreTouched = true
                break
            }
            let dbPaths: [String] = try await db.pool.read { db in
                try FileRecord.fetchAll(db).map { $0.path }
            }
            for path in dbPaths where remoteMap[path] == nil {
                let sid = ManifestSharding.shardId(for: path)
                guard affected.contains(sid) else { continue }
                // リモート削除された .syncignore も再構築の契機にする。
                if IgnoreDecision.isSyncignoreFile(path) { syncignoreTouched = true }
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

        // リモート由来の .syncignore 変更を反映（FSEvents 経由でも拾えるが pull の保険）。
        // 変化が無ければ再走査しない（定常 pull のホットパスを軽く保つ）。起動時の初期ロードは start() が行う。
        if syncignoreTouched {
            await reloadIgnoreMatcher()
        }
        await refreshQueueDepth()

        // シャード変化を取り込んだら FP ドメインへ通知（M5 Phase 4・アプリ側が主経路）。
        // 拡張は独立の etag キャッシュを持つので、既知の変化なら向こうで no-op になる。
        if !affected.isEmpty {
            FileProviderController.signalRemoteChanges()
        }
    }

    /// `reconcileRemoteEntry` の本体（依存注入の nonisolated static）。判定 → 実 I/O の switch 配線を
    /// 結合テスト可能にするため、`resolveUploadConflict` と同型で @MainActor から切り出した（#30 / D1）。
    /// @MainActor 固有の副作用は注入クロージャで配線し、@MainActor 側は下の薄いラッパに退避する。
    /// - Parameters:
    ///   - postConflictCopy: 衝突コピー生成の通知（fire-and-forget。ラッパが MainActor へ Task で逃がす）。
    ///   - recordIssue: エラーの構造化記録（@MainActor の `recordIssue(_:logAs:)` へ委譲）。
    nonisolated static func reconcileRemoteEntry(
        path: String,
        entry: ManifestFileEntry,
        dl: Downloader,
        db: LocalDatabase,
        syncRoot: URL,
        matcher: LayeredSyncIgnore,
        postConflictCopy: @Sendable (_ path: String, _ localCopyPath: String) -> Void,
        recordIssue: @Sendable (_ issue: SyncIssue, _ logAs: String?) async -> Void
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
                "Unsafe remote path rejected (manifest)"
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
        if IgnoreDecision.shouldSkip(relativePath: path, isAlreadyTracked: tracked, matcher: matcher) {
            AppLogger.sync.info("Skipping ignored remote entry: \(path, privacy: .private)")
            return
        }

        do {
            // ローカル stat（size, mtime）を取得（symlink は従来どおり追従）。stat 成功 ⟹ 存在確定。
            // steady-state（ゲート発火）はこの 1 syscall だけで抜ける（PR #20 レビュー nit-2）。
            let stat = Self.statSizeAndMtime(at: fullURL)

            // 最適化（M4・pull コスト削減）: ローカルが DB と一致し、かつ DB がリモート entry を
            // そのまま反映しているなら、hash も DB write も不要で reconcile をスキップ（証明可能な no-op）。
            // steady-state（未変化シャードは entry が DB から再合成される）では毎 pull がここで抜ける。
            if let stat, let localRec {
                let known = ChangeDetector.Known(
                    size: localRec.size, mtime: localRec.mtime,
                    sha256: localRec.sha256, isSynced: localRec.lastSyncedAt != nil
                )
                if ChangeDetector.reconcileIsNoop(
                    known: known, localSize: stat.size, localMtime: stat.mtime,
                    knownEtag: localRec.s3Etag ?? "", knownVersionId: localRec.s3VersionId,
                    remoteSha: entry.sha256, remoteEtag: entry.etag, remoteVersionId: entry.s3VersionId
                ) {
                    return
                }
            }

            // ローカル状態。不在 / 存在するがハッシュ不能 / SHA 取得済み を区別して decide() へ渡す。
            // stat 成功なら存在確定。stat 失敗時のみ fileExists で absent（不在）と unreadable（在るが
            // stat 不能＝権限/ディレクトリ等）を分ける（不在を unreadable 扱いすると renameLocalForConflict が空振る）。
            // hash は detached で（pull 中のメインスレッドブロックを解消）。
            let exists = stat != nil || FileManager.default.fileExists(atPath: fullURL.path)
            let localState: LocalState
            if exists {
                let computed = await Self.computeHashDetached(fullURL)
                localState = computed.map(LocalState.present) ?? .unreadable
            } else {
                localState = .absent
            }

            // 競合解決は ThreeWayMerge に一本化（remote はここでは常に非 nil）。
            switch ThreeWayMerge.decide(base: localRec?.sha256, local: localState, remote: entry.sha256) {
            case .download:
                // 採用未了の削除待ち（Issue #69）: 未追跡（record 無し）× ローカル不在 × 同 path の
                // delete 行 pending なら取得しない。event 側（shouldPropagateDeletion）の enqueue と
                // in-flight pull が逆転すると「復活 → 後続 delete がリモートだけ消す」片肺になる。
                // [ローカル削除の伝播待ち]（#68・base 分岐）の未追跡版＝base が無いのでキュー行を
                // 根拠にする。DB 読み失敗は従来挙動（取得）へフォールバック。
                if localRec == nil, case .absent = localState,
                   (try? await Self.hasPendingDelete(db: db, path: path)) == true {
                    AppLogger.sync.info("Skip download (untracked delete pending): \(path, privacy: .private)")
                    return
                }
                // リモート採用（ローカル欠落 / ローカル未編集でリモートのみ変化 → 上書き取得）。
                try await dl.download(relativePath: path, entry: entry)
            case .localMatchesRemote:
                // 内容一致: 書き込み不要。DB メタデータのみ最新化（mtime ドリフト修復 / etag 追従）。
                // 再 hash を避けるため download() に畳まず markSynced を直接呼ぶ。localMtime は上の stat 値。
                try await dl.markSynced(relativePath: path, entry: entry, localMtime: stat?.mtime)
            case .conflictThenDownload:
                // 双方乖離（ローカル編集 / 未追跡 / unreadable）→ ローカルをコンフリクトコピーへ退避してからリモート取得。
                let localCopy = try dl.renameLocalForConflict(relativePath: path)
                // 手動マージが要る可能性があるので通知（退避自体は成功＝download 失敗でも知らせる）。
                // fire-and-forget: 初回の許可プロンプト待ちで同期処理を止めない（PR #18 レビュー Medium）。
                postConflictCopy(path, localCopy)
                try await dl.download(relativePath: path, entry: entry)
            case .awaitLocalDeletePropagation:
                // ローカル削除の伝播待ち（base == remote・Issue #68）: download すると削除が復活する。
                // 削除の伝播は scan / event 側の enqueueDelete に委ね、ここでは何もしない。
                AppLogger.sync.info("Skip download (awaiting local-delete propagation): \(path, privacy: .private)")
            case .deleteLocal, .keepLocalRemoteDeleted, .noop:
                // remote が非 nil のここでは到達しない。来たら decide() のロジックバグ。
                assertionFailure("unreachable: remote is non-nil in reconcileRemoteEntry")
            }
        } catch {
            AppLogger.sync.error("Remote reconcile \(path, privacy: .private) failed: \(String(describing: error), privacy: .private)")
            await recordIssue(
                SyncIssueClassifier.classify(error: error, path: path),
                "Remote reconcile failed"
            )
        }
    }

    /// `reconcileRemoteEntry` static 本体への @MainActor ラッパ。@MainActor 固有の副作用
    /// （notifier 通知の fire-and-forget・`recentIssues` への記録）を注入クロージャで配線する。
    /// `performRemotePull` からの呼び出し（path/entry/dl の 3 引数）はこのラッパを通る。
    private func reconcileRemoteEntry(
        path: String,
        entry: ManifestFileEntry,
        dl: Downloader
    ) async {
        await Self.reconcileRemoteEntry(
            path: path, entry: entry, dl: dl,
            db: db, syncRoot: syncRoot, matcher: ignoreMatcher,
            postConflictCopy: { [weak self] p, c in
                Task { @MainActor in
                    await self?.notifier?.post(.conflictCopyCreated(path: p, localCopyPath: c))
                }
            },
            recordIssue: { [weak self] issue, logAs in
                await self?.recordIssue(issue, logAs: logAs)
            }
        )
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

        // .syncignore（ルート/ネスト）の変更/削除は、変更された 1 枚だけをインプレース patch して
        // （ツリー走査なし・#64）、フルスキャンで全体を再評価 + 層辞書を再構築する。
        // .syncignore 自身は同期対象（Q2）なので、この後の通常処理（アップロード/削除）も継続する。
        if IgnoreDecision.isSyncignoreFile(path) {
            await patchIgnoreLayer(forSyncignoreAt: path)
            Task { [weak self] in await self?.triggerFullScan() }
        }

        switch event.kind {
        case .createdOrModified:
            let fullURL = syncRoot.appendingPathComponent(path)
            let existing = try await db.pool.read { db in
                try FileRecord.fetchOne(db, key: path)
            }

            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: fullURL.path)
            } catch {
                // イベントと処理の間に消えた → 追跡中のみ delete として扱う（`.deleted` 分岐と対称・
                // PR #53 レビュー #1）。debounce 窓内に生成・消滅する一過性パス（ビルドツールの
                // 一時ディレクトリ等。watcher が IsDir を通すようになったぶん dir でも到達する）へ
                // 無条件 delete を発行すると、processDelete が存在ガード無しに delete marker +
                // シャード RMW を行い、未 pull のリモート追跡ファイルまで消し得る。
                guard existing != nil else { return }
                try await enqueueDelete(path: path, now: now)
                return
            }

            // 種別変化の検出（Issue #52）: path が今ディレクトリなら、通常のファイル処理
            // （classify → upload enqueue）には進ませない。upload に分類すると EISDIR で give-up し、
            // 旧ファイルの S3 delete が発行されないままマニフェストに「ファイルと同名配下」が両立する
            // 不整合が残り、pull 側が復元不能な reconcile エラーループに入る。
            // attributesOfItem は symlink を辿らない（lstat 相当）ので symlink dir を誤検出しない。
            if (attrs[.type] as? FileAttributeType) == .typeDirectory {
                // 未追跡パスの通常 dir イベント（配下書込での mtime 更新等。watcher が IsDir を
                // 通すようになったぶん頻繁に来る）は no-op。
                guard existing != nil else { return }
                // 再入ガード（PR #53 レビュー #7）: 既に同 path の delete 行があれば何もしない。
                // FileRecord は S3 delete + シャード更新の成功まで残るため、S3 障害中に dir イベントが
                // 再着火するたび .replace で積み直すと attempts が毎回リセットされ、バックオフと
                // 5 回 give-up が無効化される（多重フルスキャンの抑止も兼ねる）。
                let alreadyConverted = try await db.pool.read { db in
                    try UploadQueueRecord
                        .filter(Column("path") == path)
                        .filter(Column("operation") == "delete")
                        .fetchOne(db) != nil
                }
                if alreadyConverted { return }
                // 追跡中ファイルがディレクトリへ置換された → 旧ファイルの delete を enqueue
                // （.replace で誤分類済みの upload 行も潰す）。
                try await enqueueDelete(path: path, now: now)
                AppLogger.sync.info("File replaced by a directory; enqueued delete: \(path, privacy: .private)")
                // ディレクトリ配下の子はフルスキャンで拾う（echo で作った子は自身のイベントでも来るが、
                // `mv 既存dir path` の置換は子のイベントが出ない）。delete → 子孫 upload の順は
                // 「delete を先に enqueue + スキャン側も削除 → upload の順で enqueue（レビュー #6）」で
                // 通常成立するが、同一バッチ内の並列処理があるため厳密な順序保証ではない
                // （両立が漏れ出る伝播窓は pull 側の再 arm＝修正 C が受けて自己回復する）。
                Task { [weak self] in await self?.triggerFullScan() }
                return
            }

            // 種別変化の鏡像 = ディレクトリ → 同名ファイル置換（PR #53 レビュー #3）:
            // `mv x.dir /outside && cp f x.dir` は子のイベントが出ないため、path が今 regular file で
            // DB に `path/` 配下の追跡行が残っていたら子孫の delete をここで enqueue する。放置すると
            // マニフェストに「x.dir（ファイル）+ x.dir/…（配下）」の鏡像不整合が残り、ピア側は子 DL の
            // ENOTDIR 失敗 → 再 arm の毎 pull 再試行が（削除が来ないため）恒久化する。
            // path 自身の upload はこの後の通常経路が担う。
            let descendants = try await Self.enqueueDescendantDeletes(db: db, parentPath: path, now: now)
            if descendants > 0 {
                AppLogger.sync.info("Directory replaced by a file; enqueued \(descendants) descendant delete(s): \(path, privacy: .private)")
                await refreshQueueDepth()
            }

            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = ((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970
            // 変更判定（preDecision → verifyHash → postHash → mtime CAS）はフルスキャンと同じ
            // classifyLocalChange に集約（hash は off-main・#30 / D1 で配線テスト）。
            switch try await Self.classifyLocalChange(
                existing: existing, fileURL: fullURL, size: size, mtime: mtime,
                relativePath: path, db: db
            ) {
            case .skip, .mtimeRepaired, .mtimeCASNoop:
                return  // 無変更 or mtime 修復のみ（アップロード不要）
            case .enqueue:
                break
            }

            // 除外判定（新規被マッチはスキップ。既存追跡・.syncignore 自身は通す）
            let tracked = (existing?.lastSyncedAt != nil)
            if IgnoreDecision.shouldSkip(relativePath: path, isAlreadyTracked: tracked, matcher: ignoreMatcher) {
                return
            }

            // event は onConflict: .replace（処理中の同 path の新イベントで置換＝L6 安定化設計）。
            try await Self.enqueueUpload(db: db, path: path, now: now, onConflict: .replace)
            await refreshQueueDepth()

        case .deleted:
            let existing = try await db.pool.read { db in
                try FileRecord.fetchOne(db, key: path)
            }
            // record 不在は原則 no-op（未追跡＝同期対象外）だが、再セットアップ直後の採用未了
            // ウィンドウ（マニフェスト掲載済み・DB 採用前）では削除の黙殺になる（Issue #69）。
            // 直近 pull の remoteKnownPaths でリモート追跡分だけ伝播させる。ignore 被マッチの
            // 未追跡パスは除外（他デバイス由来でマニフェストに載っている場合、ローカルと紐付いた
            // ことのない entry を消す片方向データ破壊になる）。
            guard Self.shouldPropagateDeletion(
                isTracked: existing != nil,
                isRemoteKnown: remoteKnownPaths.contains(path),
                isIgnoredUntracked: IgnoreDecision.shouldSkip(
                    relativePath: path,
                    isAlreadyTracked: existing?.lastSyncedAt != nil,
                    matcher: ignoreMatcher
                )
            ) else { return }
            try await enqueueDelete(path: path, now: now)
        }
    }

    private func enqueueDelete(path: String, now: Double) async throws {
        try await Self.enqueueDelete(db: db, path: path, now: now)
        await refreshQueueDepth()
    }

    /// `remoteKnownPaths` のシャード単位マージ（Issue #69・PR #71 レビュー指摘 1 で純関数化）。
    /// 変化/削除シャード（`affectedShards`）に属する前回分は差し替え（脱落）、無変化シャード分は
    /// 温存し、今回 pull の全 path（`freshPaths`）を合流させる。**丸ごと差し替えにしてはならない** —
    /// `ManifestReader.read()` は無変化シャードを FileRecord から再合成する（＝採用済みサブセット
    /// しか返さない）ため、2 回目以降の pull で未採用 path が集合から脱落し、採用未了ウィンドウの
    /// 削除黙殺（#69 の窓）が再び開く。回帰は `ScanEventWiringTests` のマージ規則 3 点。
    nonisolated static func mergedRemoteKnownPaths(
        previous: Set<String>, affectedShards: Set<String>, freshPaths: some Sequence<String>
    ) -> Set<String> {
        previous
            .filter { !affectedShards.contains(ManifestSharding.shardId(for: $0)) }
            .union(freshPaths)
    }

    /// event `.deleted` の伝播判定（Issue #69）。追跡済み（FileRecord あり）は従来どおり常に伝播。
    /// 未追跡は「リモート既知（直近 pull の `remoteKnownPaths` 掲載）かつ ignore 非該当」のときだけ
    /// 伝播する＝再セットアップ直後の採用未了ウィンドウの削除を拾う。
    /// **この判定をフルスキャンへ展開してはならない** — 「リモート既知だが record も実ファイルも無い」を
    /// scan で delete に倒すと、クリーンインストール復旧中の未ダウンロードファイル全部に delete を打つ。
    /// FSEvents の `.deleted` イベント（＝ローカルに実在したものが消えた証跡）に限定するのが load-bearing。
    nonisolated static func shouldPropagateDeletion(
        isTracked: Bool, isRemoteKnown: Bool, isIgnoredUntracked: Bool
    ) -> Bool {
        if isTracked { return true }
        return isRemoteKnown && !isIgnoredUntracked
    }

    /// 同 path の delete 行がキューに存在するか（Issue #69 の pull 側ガード用・読み取りのみ＝
    /// [キュー行 id 基準] 非抵触）。
    nonisolated static func hasPendingDelete(db: LocalDatabase, path: String) async throws -> Bool {
        try await db.pool.read { db in
            try UploadQueueRecord
                .filter(Column("path") == path)
                .filter(Column("operation") == "delete")
                .fetchOne(db) != nil
        }
    }

    /// delete キューへ 1 行投入する（常に onConflict: .replace ＝処理中の同 path 行を置換する。
    /// 種別変化（Issue #52）では誤分類済みの upload 行をこれで潰す）。event 経路と
    /// 配線テスト（`ScanEventWiringTests`）が共用する nonisolated static（`enqueueUpload` と同型）。
    nonisolated static func enqueueDelete(db: LocalDatabase, path: String, now: Double) async throws {
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
    }

    /// ディレクトリ → 同名ファイル置換（種別変化の鏡像・PR #53 レビュー #3）で、`parentPath/` 配下に
    /// 残っている追跡行すべてを delete キューへ投入する。
    /// 前方一致は LIKE ではなく **PK の範囲比較**で拾う: `"/"` の次のバイトは `"0"` なので、
    /// binary collation（SQLite TEXT 既定・UTF-8 は memcmp で接頭辞順序を保存）では
    /// `path >= "p/" AND path < "p0"` が「`p/` で始まる全パス」と正確に一致し、インデックスも効く
    /// （LIKE は `%`/`_` を含むファイル名でエスケープが要り、既定では index も使わない）。
    /// 既に delete 行がある子孫はスキップする（親分岐の再入ガードと同型・PR #53 再レビュー）:
    /// S3 障害中に置換後ファイルへのイベントが再着火するたび `.replace` で積み直すと、リトライ中の
    /// 子孫 delete 行の attempts が毎回リセットされ、バックオフ / give-up が無効化される。
    /// stale な upload 行は従来どおり `.replace` で delete へ置換する。
    /// - Returns: 今回 enqueue（新規 or upload 行から置換）した削除件数。0 = 配下の追跡行なし、
    ///   または全子孫が delete 変換済み（呼び元はログも `refreshQueueDepth` も抑止できる）。
    nonisolated static func enqueueDescendantDeletes(
        db: LocalDatabase, parentPath: String, now: Double
    ) async throws -> Int {
        let lower = parentPath + "/"
        let upper = parentPath + "0"
        let paths: [String] = try await db.pool.read { db in
            try FileRecord
                .filter(Column("path") >= lower && Column("path") < upper)
                .fetchAll(db)
                .map(\.path)
        }
        guard !paths.isEmpty else { return 0 }
        return try await db.pool.write { db in
            var enqueued = 0
            for p in paths {
                if let existing = try UploadQueueRecord
                    .filter(Column("path") == p)
                    .fetchOne(db), existing.operation == "delete" {
                    continue
                }
                var rec = UploadQueueRecord(
                    id: nil,
                    path: p,
                    operation: "delete",
                    enqueuedAt: now,
                    attempts: 0,
                    nextRetryAt: nil,
                    lastError: nil
                )
                try rec.insert(db, onConflict: .replace)
                enqueued += 1
            }
            return enqueued
        }
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
            uploadLimiter: uploadLimiter,
            // マニフェスト書込の確定点（ManifestUpdater 成功）で FP ドメインへ通知
            //（M5 Phase 5-0 / PR #51 レビュー #4）。旧バッチ集約（anySucceeded）は
            // マニフェスト PUT 成功後の DB write throw で 1 バッチ分 signal が漏れる窓があった。
            onManifestWrite: { Task { @MainActor in FileProviderController.signalRemoteChanges() } }
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

            // 有界並列の骨格は BoundedParallel に一元化（PR #50 レビュー #7 / PR #51 レビュー #7）。
            // transform は非 throw なので try? は実際には失敗しない（throws は transform 由来のみ）。
            // FP ドメインへの通知はここではなく uploader の onManifestWrite（マニフェスト書込の
            // 確定点）で発火する（M5 Phase 5-0）。
            let local = uploader
            _ = try? await BoundedParallel.compactMap(items, limit: 5) { [weak self] item in
                await self?.processOne(item, uploader: local)
            }
            await refreshQueueDepth()
            lastSyncedAt = Date()
        }
    }

    /// キュー 1 件を処理し、失敗はリトライ/バックオフ/give-up へ配線する。
    /// 成否の戻り値は持たない（FP への通知は uploader の onManifestWrite＝マニフェスト書込の
    /// 確定点が担うため、呼び出し側はバッチの成否を集約しない。M5 Phase 5-0）。
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

        // Issue #25 (A): 書込シームで並行更新を検出した。ローカル編集をコンフリクトコピーへ退避し、
        // リモート版を正規パスへ取得し直す（pull 側 .conflictThenDownload と対称）。give-up に載せない。
        if case let SyncError.uploadConflict(_, remoteEntry) = error {
            if await handleUploadConflict(item: item, remoteEntry: remoteEntry) { return }
            // 行除去すらできなかった（DB 失敗）場合のみ generic backoff へフォールスルー
            // （行は残存・ローカルファイルは無傷・リネームもしていない＝再試行で自己修復）。
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

    /// アップロード競合（Issue #25 / A）の解決を起動する @MainActor ラッパ。
    /// 本体は回帰テスト可能な `nonisolated static resolveUploadConflict` に切り出し（`UploaderConflictTests`）、
    /// ここでは Downloader 構築・recordIssue / 通知の発火という @MainActor 依存だけを担う。
    /// - Returns: 行を item.id 基準で除去できたら true（呼出側は return）。除去すらできなければ false
    ///   （呼出側は generic backoff へフォールバック）。
    private func handleUploadConflict(item: UploadQueueRecord, remoteEntry: ManifestFileEntry) async -> Bool {
        let dl = makeDownloader()
        let result = await Self.resolveUploadConflict(
            item: item,
            remoteEntry: remoteEntry,
            db: db,
            downloader: dl,
            recordIssue: { [weak self] error in
                await self?.recordIssue(SyncIssueClassifier.classify(error: error, path: item.path))
            }
        )
        // 退避コピーを作れたら手動マージの可能性を通知（fire-and-forget・pull 側と同じ既存イベント）。
        if let copy = result.conflictCopyPath {
            Task { await self.notifier?.post(.conflictCopyCreated(path: item.path, localCopyPath: copy)) }
        }
        return result.tookOwnership
    }

    /// アップロード競合解決の本体（回復可能順序）。`pruneOrphanTransfers` と同型の依存注入 static。
    ///
    /// 不変条件: **リネームはキュー行除去を決して上回らない**。先に item.id 基準で行を除去し、成功した
    /// 場合にのみ不可逆な `renameLocalForConflict`（FS 移動 + FileRecord 削除）へ進む。これにより
    /// 「canonical 消失 + キュー行残存」を作らない（さもないと再処理が `convertQueueItemToDelete` →
    /// リモート delete-marker ＝他端末のデータ損失）。
    ///
    /// 失敗時はすべて次回 pull で自己回復する: rename 失敗ならローカルが残り pull 側 `.conflictThenDownload`
    /// が退避+取得、download 失敗なら `local absent + remote present → .download` で正規パスを再投入。
    nonisolated static func resolveUploadConflict(
        item: UploadQueueRecord,
        remoteEntry: ManifestFileEntry,
        db: LocalDatabase,
        downloader: Downloader,
        recordIssue: @Sendable (Error) async -> Void
    ) async -> UploadConflictResolution {
        // 1. キュー行を item.id 基準で除去（give-up 加算なし）。失敗なら何も壊さず呼出側へ委ねる。
        do {
            try await db.pool.write { db in
                try UploadQueueRecord
                    .filter(Column("id") == item.id)
                    .deleteAll(db)
            }
        } catch {
            AppLogger.sync.error("Upload-conflict: failed to remove queue row for \(item.path, privacy: .private): \(String(describing: error), privacy: .private)")
            return UploadConflictResolution(tookOwnership: false, conflictCopyPath: nil)
        }

        // 2. ローカル編集をコンフリクトコピーへ退避（FileRecord も削除）。行は既に除去済みなので、
        //    ここで失敗してもリモート delete-marker は起き得ない。次回 pull が退避+取得して回復する。
        let localCopy: String
        do {
            localCopy = try downloader.renameLocalForConflict(relativePath: item.path)
        } catch {
            AppLogger.sync.error("Upload-conflict: rename failed for \(item.path, privacy: .private) (will heal on next pull): \(String(describing: error), privacy: .private)")
            await recordIssue(error)
            return UploadConflictResolution(tookOwnership: true, conflictCopyPath: nil)
        }

        // 3. ベストエフォートでリモート版を正規パスへ。versionId 指定で相手版を確実に取得（本体 PUT が
        //    最新を自分の内容に変えているため）。キュー行は id 基準で所有済みなので path 基準削除はしない。
        do {
            try await downloader.download(
                relativePath: item.path,
                entry: remoteEntry,
                versionId: remoteEntry.s3VersionId,
                clearQueueByPath: false
            )
        } catch {
            AppLogger.sync.error("Upload-conflict: download of remote version failed for \(item.path, privacy: .private) (will heal on next pull): \(String(describing: error), privacy: .private)")
            await recordIssue(error)
            // 退避は成功しているので通知はする（手動マージ可能・正規パスは次回 pull で回復）。
        }

        return UploadConflictResolution(tookOwnership: true, conflictCopyPath: localCopy)
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
                // id タイブレーク（PR #53 再レビュー nit）: フルスキャンの「削除検出 → upload」は
                // 同一 now で enqueue するため、同時刻内は insert 順（= delete 先行）を形式化する。
                .order(Column("enqueued_at"), Column("id"))
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

    /// recentIssues への積み方（純粋関数）。**同一 (path, category) は最新のみ保持**してから末尾へ積み、
    /// 上限 `cap` の FIFO で古いものを落とす。リトライごとに同一エラーが積み上がり（give-up までに同カテゴリ
    /// 最大 5 件）、上限到達時に他カテゴリを押し流すのを防ぐ（#32 / D3・PR #17 nit-4）。古い同一キーを除いて
    /// から末尾へ足すので「最新が末尾」の不変条件（`MenuBarPresentation.groupIssues` は reversed で新しい順に走査）
    /// を保つ。path は `String?` で nil 同士も同一キー（path なしの pull 全体失敗等も最新のみ残る）。
    nonisolated static func appendDeduped(_ issues: [SyncIssue], _ issue: SyncIssue, cap: Int = 50) -> [SyncIssue] {
        var next = issues.filter { !($0.path == issue.path && $0.category == issue.category) }
        next.append(issue)
        if next.count > cap { next.removeFirst(next.count - cap) }
        return next
    }

    /// 分類済み issue を recentIssues に積む（同一 (path, category) は最新のみ・上限 50・FIFO＝`appendDeduped`）。
    /// `logAs` に英語固定文を渡すと sync_log("error") にも 1 行残す（message = 固定文、details = rawDetail）。nil は
    /// 呼び元が自前の write Tx 内で原子的に書く箇所（fileTooLarge / give-up / 不安定警告）か、
    /// リトライごとの重複記録を避けたい箇所（give-up 前の各失敗）。
    private func recordIssue(_ issue: SyncIssue, logAs logMessage: String? = nil) async {
        recentIssues = Self.appendDeduped(recentIssues, issue)
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

/// `SyncEngine.resolveUploadConflict` の結果（Issue #25 / A）。
struct UploadConflictResolution: Equatable, Sendable {
    /// item.id 基準でキュー行を除去できたか。false なら呼出側は generic backoff へフォールバックする
    /// （行は残存・ローカルファイルは無傷・リネームもしていない）。
    let tookOwnership: Bool
    /// 退避したコンフリクトコピーの相対パス。非 nil なら `.conflictCopyCreated` を通知する。
    /// nil（rename 失敗で次回 pull に委ねる場合）は通知しない。
    let conflictCopyPath: String?
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
