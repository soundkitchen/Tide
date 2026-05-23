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

    // MARK: - Dependencies

    private let db: LocalDatabase
    private let s3: TideS3Client
    private let syncRoot: URL
    private let deviceId: String
    private let tmpDir: URL

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

    let pollIntervalSeconds: Int

    init(
        db: LocalDatabase,
        s3: TideS3Client,
        syncRoot: URL,
        deviceId: String,
        pollIntervalSeconds: Int = 180
    ) {
        self.db = db
        self.s3 = s3
        self.syncRoot = syncRoot
        self.deviceId = deviceId
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
            await self?.triggerFullScan()
            await self?.triggerRemotePull()
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
        status = .notConfigured
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
        if remotePullInFlight { return }
        remotePullInFlight = true
        defer { remotePullInFlight = false }
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
                if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }
                // C1: 念のため相対パスを検証（root エスケープを防ぐ）
                do {
                    try PathValidator.validateRelativePath(relative)
                } catch {
                    continue
                }

                foundPaths.insert(relative)

                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0

                let existing = try await db.pool.read { db in
                    try FileRecord.fetchOne(db, key: relative)
                }

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
            s3: s3,
            db: db,
            syncRoot: syncRoot,
            tmpDir: tmpDir,
            deviceId: deviceId
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

        let exists = FileManager.default.fileExists(atPath: fullURL.path)

        do {
            if !exists {
                try await dl.download(relativePath: path, entry: entry)
                return
            }

            // ローカル SHA を計算
            let localSha: String
            do {
                localSha = try HashCalculator.sha256(of: fullURL)
            } catch {
                try await dl.download(relativePath: path, entry: entry)
                return
            }

            if localSha == entry.sha256 {
                // 内容が一致しているのに DB エントリが古い/無い可能性 → download() の早期 return パスで DB を最新化
                try await dl.download(relativePath: path, entry: entry)
                return
            }

            // SHA が違う
            if let rec = localRec, rec.sha256 == localSha {
                // ローカルは前回同期後に触られていない → リモートで更新されたので上書き
                try await dl.download(relativePath: path, entry: entry)
                return
            }

            // ローカルが触られている / DB 記録なし → コンフリクト
            _ = try dl.renameLocalForConflict(relativePath: path)
            try await dl.download(relativePath: path, entry: entry)
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
        let uploader = Uploader(s3: s3, db: db, syncRoot: syncRoot, deviceId: deviceId)
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
        await appendError("\(item.path): \(error)")
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
