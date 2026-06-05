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
    var recentErrors: [String] = []

    /// 現在有効な `.syncignore` のパターン行（Settings 表示用）。
    var activeIgnorePatterns: [String] = []

    /// 進行中の転送（メニューバーのポップオーバー表示用）。off-main の Uploader / Downloader が
    /// `@Sendable` reporter を通じて MainActor で更新する。(path, direction) で一意。
    var activeTransfers: [TransferProgress] = []

    // MARK: - Dependencies

    private let db: LocalDatabase
    private let s3: TideS3Client
    private let syncRoot: URL
    private let deviceId: String
    private let tmpDir: URL
    private let config: ConfigStore

    // MARK: - Internals

    private var watcher: FileWatcher?
    private var debouncer: DebounceQueue<FileChangeEvent>?
    private var watchTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var wakeObserverTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var remotePullInFlight: Bool = false
    private var paused: Bool = false
    private var running: Bool = false
    private var ignoreMatcher: SyncIgnoreMatcher = .empty

    let pollIntervalSeconds: Int

    init(
        db: LocalDatabase,
        s3: TideS3Client,
        syncRoot: URL,
        deviceId: String,
        config: ConfigStore,
        pollIntervalSeconds: Int = 180
    ) {
        self.db = db
        self.s3 = s3
        self.syncRoot = syncRoot
        self.deviceId = deviceId
        self.config = config
        self.pollIntervalSeconds = max(30, pollIntervalSeconds)

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
            status = .error(String(describing: error))
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
            // （triggerRemotePull 内の remotePullInFlight で排他＝並行 DL を防止）。
            await self?.triggerRemotePullSafely(reason: "startup")
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
    /// - upload: ローカルファイルが消えた行は宙ぶらりんの MPU を best-effort abort して削除。
    /// - download: tmp が消えた行は削除（再開対象が無い）。
    /// - 両方向とも 7 日より古い行は失効扱い（S3 の `tide-abort-incomplete-multipart` と歩調を合わせる）。
    private func pruneOrphanTransfers() async {
        let store = TransferStateStore(db: db)
        let rows: [TransferStateRecord]
        do {
            rows = try await store.allEntries()
        } catch {
            AppLogger.sync.error("Transfer-state prune: list failed: \(String(describing: error), privacy: .private)")
            return
        }
        guard !rows.isEmpty else { return }

        let staleCutoff = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        for row in rows {
            let isStale = row.updatedAt < staleCutoff
            switch row.direction {
            case TransferDirection.upload.rawValue:
                let fileExists = (try? PathValidator.resolveSafely(relativePath: row.path, syncRoot: syncRoot))
                    .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                guard !fileExists || isStale else { continue }
                if let uploadId = row.uploadId {
                    try? await s3.abortMultipartUpload(key: "files/\(row.path)", uploadId: uploadId)
                }
                try? await store.clearUpload(path: row.path)
                AppLogger.sync.info("Pruned orphan upload transfer: \(row.path, privacy: .private)")
            case TransferDirection.download.rawValue:
                let tmpMissing = row.tmpPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
                if !tmpMissing && !isStale {
                    // 再開可能（tmp あり・新しい）: 次回 pull で確実に reconcile されるよう、この path の
                    // シャードの shard_state を無効化する。さもないと「シャードは取得済み（DL 完了前に
                    // ManifestReader が記録）＋ DL 未完で FileRecord 無し」のため pull が当該ファイルを
                    // 見落とし、Downloader の Range 再開に到達しない（中断ダウンロードの取り残し）。
                    // シャードを invalidate すれば pull が S3 から再取得 → reconcile → 既存 tmp で Range 再開。
                    let sid = ManifestSharding.shardId(for: row.path)
                    try? await db.pool.write { db in
                        _ = try ShardStateRecord.filter(Column("shard_id") == sid).deleteAll(db)
                    }
                    AppLogger.sync.info("Re-arm resumable download (invalidated shard cache): \(row.path, privacy: .private)")
                    continue
                }
                if let tmp = row.tmpPath { try? FileManager.default.removeItem(atPath: tmp) }
                try? await store.clearDownload(path: row.path)
                AppLogger.sync.info("Pruned orphan download transfer: \(row.path, privacy: .private)")
            default:
                // 未知の direction は安全側で除去（両系を試みる）。
                try? await store.clearUpload(path: row.path)
                try? await store.clearDownload(path: row.path)
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
                await self?.triggerRemotePullSafely(reason: "poll")
            }
        }
    }

    private func startWakeObserver() {
        #if canImport(AppKit)
        wakeObserverTask = Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                if Task.isCancelled { return }
                await self?.triggerRemotePullSafely(reason: "wake")
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
                    await self?.triggerRemotePullSafely(reason: "network-up")
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func triggerRemotePullSafely(reason: String) async {
        // 再入ガードは triggerRemotePull() 側へ移設済み（全経路を単一ゲートで排他）。
        // ここでは契機（reason）をログするだけ。
        AppLogger.sync.info("Triggering remote pull (\(reason, privacy: .private))")
        await triggerRemotePull()
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
            await appendError("Full scan failed: \(error)")
        }
    }

    private func performFullScan() async throws {
        let root = self.syncRoot
        let dev = self.deviceId
        let db = self.db
        let matcher = self.ignoreMatcher
        let now = Date().timeIntervalSince1970

        let result: (newEnqueued: Int, deletedEnqueued: Int) = try await Task.detached(priority: .utility) { () -> (Int, Int) in
            var foundPaths: Set<String> = []
            var newEnqueued = 0
            var deletedEnqueued = 0

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

                let needsEnqueue: Bool
                if let existing {
                    let sizeMatches = existing.size == size
                    let mtimeMatches = abs(existing.mtime - mtime) < 0.001
                    if sizeMatches && mtimeMatches && existing.lastSyncedAt != nil {
                        needsEnqueue = false
                    } else {
                        needsEnqueue = true
                    }
                } else {
                    needsEnqueue = true
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

            return (newEnqueued, deletedEnqueued)
        }.value

        AppLogger.sync.info("Full scan: enqueued \(result.newEnqueued) uploads, \(result.deletedEnqueued) deletes")
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

    /// リモート（S3）の変更をローカルに取り込む。
    /// - シャード etag キャッシュ (`shard_state`) で差分のみ処理
    /// - ローカル無しならダウンロード / SHA 衝突ならリネームしてからダウンロード
    /// - 変更があったシャードに属していたが remoteMap から消えたファイルは applyRemoteDeletion
    func triggerRemotePull() async {
        // 並行 pull を構造的に禁止する単一ゲート。start()（起動時）・メニューの「S3 から取得」・
        // poll / wake / network のすべてがこの公開メソッドを通るので、ここで排他すれば
        // 同一ファイルが複数の reconcile から同時にダウンロードされ、決定的 tmp
        // （dl-<sha(path)>.part）への並行追記で破損するのを防げる。
        // @MainActor なので check と set の間に await が無く、2 つの呼びが割り込まずに直列化される。
        if remotePullInFlight { return }
        remotePullInFlight = true
        defer { remotePullInFlight = false }
        AppLogger.sync.info("Starting remote pull")
        do {
            try await performRemotePull()
            lastRemoteCheckedAt = Date()
        } catch {
            AppLogger.sync.error("Remote pull failed: \(String(describing: error), privacy: .private)")
            await appendError("Remote pull failed: \(error)")
        }
    }

    private func performRemotePull() async throws {
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
            progressReporter: makeProgressReporter()
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
                    await appendError("\(path): \(error)")
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
            await appendError("Unsafe remote path rejected")
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
                _ = try dl.renameLocalForConflict(relativePath: path)
                try await dl.download(relativePath: path, entry: entry)
            case .deleteLocal, .keepLocalRemoteDeleted, .noop:
                // remote が非 nil のここでは到達しない。来たら decide() のロジックバグ。
                assertionFailure("unreachable: remote is non-nil in reconcileRemoteEntry")
            }
        } catch {
            AppLogger.sync.error("Remote reconcile \(path, privacy: .private) failed: \(String(describing: error), privacy: .private)")
            await appendError("\(path): \(error)")
        }
    }

    // MARK: - Event handling

    private func handleDebounced(_ event: FileChangeEvent) async {
        do {
            try await processEventToQueue(event)
        } catch {
            AppLogger.sync.error("Failed to enqueue change for \(event.relativePath, privacy: .private): \(String(describing: error), privacy: .private)")
            await appendError("\(event.relativePath): \(error)")
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
            if let existing,
               existing.size == size,
               abs(existing.mtime - mtime) < 0.001,
               existing.lastSyncedAt != nil {
                return  // unchanged
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

    // MARK: - Queue processing loop

    private func runQueueLoop() async {
        let uploader = Uploader(
            s3: s3, db: db, syncRoot: syncRoot, deviceId: deviceId, config: config,
            transferStore: TransferStateStore(db: db),
            progressReporter: makeProgressReporter()
        )
        while !Task.isCancelled {
            if paused {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
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
        // サイズ上限超過は恒久的失敗（リトライしても無駄）。黙ってスキップせず、ユーザ向けに
        // ローカライズしたメッセージを recentErrors に出す（生エラー文字列ではなく一級 UX 状態として扱う）。
        if case SyncError.fileTooLarge = error {
            await appendError(String(localized: "\(item.path) exceeds the upload size limit and was not backed up. Increase the limit in Settings."))
            do {
                try await db.pool.write { db in
                    try UploadQueueRecord
                        .filter(Column("path") == item.path)
                        .deleteAll(db)
                    var log = SyncLogRecord(
                        id: nil,
                        timestamp: Date().timeIntervalSince1970,
                        eventType: "error",
                        path: item.path,
                        message: "Exceeds the per-file upload size limit; not backed up. Adjust the limit in Settings.",
                        details: nil
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
            await appendError("\(item.path): \(error)")
        }

        let attempts = item.attempts + 1
        let now = Date().timeIntervalSince1970

        if attempts >= 5 {
            do {
                try await db.pool.write { db in
                    try UploadQueueRecord
                        .filter(Column("path") == item.path)
                        .deleteAll(db)
                    var log = SyncLogRecord(
                        id: nil,
                        timestamp: now,
                        eventType: "error",
                        path: item.path,
                        message: "Gave up after \(attempts) attempts: \(error)",
                        details: nil
                    )
                    try log.insert(db)
                }
            } catch {
                AppLogger.db.error("Failed to record give-up: \(String(describing: error), privacy: .private)")
            }
            return
        }

        let delay = Self.backoffDelay(attempts: attempts)
        let nextRetry = now + delay

        do {
            try await db.pool.write { db in
                if var existing = try UploadQueueRecord
                    .filter(Column("path") == item.path)
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

    private func appendError(_ message: String) async {
        recentErrors.append(message)
        if recentErrors.count > 50 { recentErrors.removeFirst(recentErrors.count - 50) }
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
