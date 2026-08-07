import TideCore
import AppKit
import Foundation
import Observation

/// 依存性注入用のコンテナ。アプリ全体で 1 つ。
@MainActor
@Observable
final class AppEnvironment {
    let config: ConfigStore
    let keychain: KeychainStore
    /// OS 通知の発行とクリック処理（アプリ全体で 1 つ）。SyncEngine へ注入し、クリック時の
    /// Sync Activity オープンは App 層が `openActivity` に登録する。
    let notifications: NotificationManager

    var database: LocalDatabase?
    var s3: TideS3Client?
    var engine: SyncEngine?
    /// FP-only 稼働モード（Track B）のリモート変更検知。`fpOnly` 起動時のみ非 nil
    /// （`engine` とは相互排他 = モードごとにどちらか一方だけが立つ）。
    var signaler: RemoteChangeSignaler?

    var isSetupCompleted: Bool { config.setupCompleted }

    /// 起動失敗を bootstrap が記録する。UI 側で「ウィザード強制表示」のヒントに使う。
    var bootstrapFailure: String?

    /// 設定 import（#29）で Settings 画面からセットアップウィザードへ接続設定を引き渡すための一時バッファ。
    /// 接続変更はローカル DB がバケットに紐づくためホットスワップせず、ウィザードで再プロビジョニングする。
    /// ウィザードは `.onChange(of:initial:true)` でこれを読んでフィールドを事前充填し、消費後に nil へ戻す
    /// （単一・常駐 Window なので onAppear 再発火に頼れない。詳細は SetupWizardWindow / docs/08）。
    var pendingImportedSettings: SettingsTransfer.Payload?

    /// bootstrap の再入ガード。eager（AppDelegate）と遅延（MenuBarContent.task）の 2 経路が
    /// 並行して呼ばれ得るため、`engine` がまだ nil の `await launchEngineFromCurrentConfig()` 実行中に
    /// もう一方が guard を抜けて二重に SyncEngine を起動するのを防ぐ。
    @ObservationIgnored private var isBootstrapping = false

    /// 現在 security-scoped アクセスを保持している同期フォルダ（App Sandbox・M5 Phase 2）。
    /// メニューバー常駐でアプリ生存中はアクセスを保持し続けるので stopAccessing は基本呼ばない。
    /// ウィザード再設定でフォルダが変わった時だけ古い方を明示的に手放す。
    @ObservationIgnored private var accessedSyncRootURL: URL?

    init() {
        let config = ConfigStore()
        self.config = config
        self.keychain = KeychainStore()
        self.notifications = NotificationManager(config: config)
    }

    /// アプリ起動時のブートストラップ。設定済みなら SyncEngine を立ち上げる。
    /// 失敗した場合は bootstrapFailure に詳細を書いて UI 側にウィザード再表示を促す。
    /// 冪等: 既に起動済み（`engine != nil`）なら bootstrapFailure をクリアして即 return（自己修復）、
    /// 起動処理進行中（`isBootstrapping`）なら bootstrapFailure を触らず即 return。
    func bootstrap() async {
        // XCTest 実行中は実 SyncEngine を起動しない。テストは本体アプリ（Tide.app）にホストされて
        // 起動するため、ここを抑止しないとテストのたびに実 S3 と同期してしまう。
        // eager 経路（AppDelegate）・遅延経路（MenuBarContent.task）の両方がこのチョークポイントを通る。
        guard !ProcessInfo.processInfo.isRunningXCTests else {
            AppLogger.ui.info("Skipping bootstrap under XCTest.")
            return
        }
        if engine != nil || signaler != nil {
            // 既に動いている＝失敗状態は解消済み（fpOnly は engine の代わりに signaler が立つ）。
            // 早期 return でも bootstrapFailure をクリアして旧来の「毎回先頭でクリア」自己修復を温存する。
            // さもないと「失敗→ウィザードで復旧→正常稼働」後も bootstrapFailure が残り、
            // ポップオーバーを開くたびにウィザードが再表示され続ける（PR #7 レビュー Medium）。
            bootstrapFailure = nil
            return
        }
        if isBootstrapping {
            return  // 起動処理進行中（bootstrapFailure は触らない＝進行中の launch に委ねる）
        }
        isBootstrapping = true
        defer { isBootstrapping = false }
        bootstrapFailure = nil
        // 旧 identifier（PoC 世代）の FP ドメインが残っていれば現行 identifier で作り直す。
        // fire-and-forget（XPC 待ちで起動をブロックしない）・no-op が定常。
        Task { await FileProviderController.migrateStaleDomainsIfNeeded() }
        // 旧ロケーション（非 App Group 時代）からの一度きり移行（M5 Phase 2）。冪等・非致命。
        // setupCompleted の判定より前に行う必要がある（設定自体が移行対象のため）。
        let migration = LegacyStateMigrator.migrateIfNeeded()
        if migration.databaseMigrated || migration.configMigrated {
            AppLogger.ui.info("Legacy state migrated to App Group (db: \(migration.databaseMigrated), config: \(migration.configMigrated))")
        }
        // v0.3.0（#96）正規化書込: 保存値を常に fpOnly へ揃える。`defaults write` で folderSync を
        // 書かれても次回起動で上書き＝脱出口を封鎖する。syncMode は外部ツール
        // （tools/soak/consistency_check.py）が読む契約キーのため、書込で保存値を恒久 fpOnly に
        // 保つことが soak 突合ガード（exit 2）と DB 凍結見張り武装の維持条件（docs/09 v0.3.0 節）。
        if config.syncMode != .fpOnly {
            AppLogger.ui.info("Normalizing stored syncMode to fpOnly (was \(self.config.syncMode.rawValue, privacy: .private))")
            config.syncMode = .fpOnly
        }
        guard config.setupCompleted else {
            AppLogger.ui.info("Setup not completed; awaiting wizard.")
            return
        }
        do {
            try await launchEngineFromCurrentConfig()
        } catch {
            let detail = String(describing: error)
            AppLogger.ui.error("Bootstrap failed: \(detail, privacy: .private)")
            bootstrapFailure = detail
        }
    }

    /// nil または空文字を「未設定」とみなす（必須設定の検証用）。
    private static func isBlank(_ s: String?) -> Bool { s?.isEmpty ?? true }

    func launchEngineFromCurrentConfig() async throws {
        // v0.3.0（#96）: boot は syncMode を読まず常に fpOnly。folderSync（FSEvents エンジン）への
        // 分岐は**この関数内部**で閉じる — 呼出経路は bootstrap() と completeSetup の 2 つあり、
        // 呼出側ゲートだと旧ウィザード再セットアップ経由で FSEvents エンジンが起動し得る
        // （空フォルダ受理 → 全件 delete の事故窓。docs/09 v0.3.0 節・PR #99 レビュー指摘 2）。
        try await launchFPOnlySignalerFromCurrentConfig()
    }

    /// 【到達不能・温存】folderSync（FSEvents）モードの起動本体。v0.3.0（#96）で呼出経路ゼロの
    /// デッドコードになった。復活手段は git revert のみ（docs/09「revert 復帰ランブック」の遵守必須 —
    /// ランブック無しの revert 起動は空フォルダ受理 → S3 一斉 delete marker の事故窓へ直行する）。
    /// SyncEngine / FileWatcher 一式のコンパイル維持のため温存し、物理削除は従来ゲート
    /// （FP-only 無事故実績 + 2 台 soak 後 = docs/09 M5 節）まで据え置き。
    private func launchFolderSyncEngineFromCurrentConfig() async throws {
        var missing: [String] = []
        if Self.isBlank(config.bucketName) { missing.append("bucket name") }
        if Self.isBlank(config.region) { missing.append("region") }
        if Self.isBlank(config.syncRootPath) { missing.append("sync folder") }
        if !missing.isEmpty {
            throw SyncError.notConfigured(reason: "Missing: \(missing.joined(separator: ", "))")
        }
        let bucket = config.bucketName!
        let region = config.region!
        let rootPath = config.syncRootPath!

        let credentials = try loadCredentialsOrThrow()
        let dbURL = try LocalDatabase.defaultURL()
        let db = try LocalDatabase(at: dbURL)
        try db.pruneOldLogs()

        let s3 = try TideS3Client(
            credentials: credentials,
            region: region,
            bucket: bucket,
            deviceId: config.deviceId
        )

        // syncRoot アクセス解決（App Sandbox・M5 Phase 2）: security-scoped bookmark を解決して
        // アクセスを開始する。bookmark 欠落/失効（サンドボックス化前の版からのアップグレード等）は
        // 起動時の再許可パネルで一度だけ取り直す。存在チェックはアクセス確立後でないと成立しない。
        let url = try await resolveSyncRootAccess(rootPath: rootPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.invalidSyncRoot("does not exist or is not a directory: \(rootPath)")
        }

        let engine = SyncEngine(
            db: db,
            s3: s3,
            syncRoot: url,
            deviceId: config.deviceId,
            config: config,
            pollIntervalSeconds: config.pollingIntervalSeconds,
            notifier: notifications
        )
        self.database = db
        self.s3 = s3
        self.engine = engine
        await engine.start()

        Self.enforceTLSBucketPolicyDetached(s3: s3)
    }

    /// FP-only 稼働モード（Track B）の起動: SyncEngine（FSEvents 監視・pull・アップロードキュー）を
    /// 起動せず、`RemoteChangeSignaler` だけを立ち上げる。**DB / syncRoot / bookmark には一切
    /// 触れない**（凍結温存 = `folderSync` 復帰時に SyncEngine の pull が shard_state の etag 差分で
    /// FP-only 期間中の変化を増分検出できる。DB を開かないので `pruneOldLogs` 等の書込も走らない）。
    /// syncRootPath / bookmark は必須設定から外れる（ローカル面が無いモードのため検証しない）。
    private func launchFPOnlySignalerFromCurrentConfig() async throws {
        var missing: [String] = []
        if Self.isBlank(config.bucketName) { missing.append("bucket name") }
        if Self.isBlank(config.region) { missing.append("region") }
        if !missing.isEmpty {
            throw SyncError.notConfigured(reason: "Missing: \(missing.joined(separator: ", "))")
        }
        let credentials = try loadCredentialsOrThrow()
        let s3 = try TideS3Client(
            credentials: credentials,
            region: config.region!,
            bucket: config.bucketName!,
            deviceId: config.deviceId
        )
        self.s3 = s3

        // FP ドメイン未登録なら signal は向こうの isEnabled ガードで no-op になる（起動自体は
        // 続行 = 設定画面から Enable すれば次の契機から効き始める）。気づけるようログだけ残す。
        if await !FileProviderController.isEnabled() {
            AppLogger.ui.info("FP-only mode: File Provider domain is not enabled yet; enable it in Settings")
        }

        let signaler = RemoteChangeSignaler(
            intervalSeconds: config.pollingIntervalSeconds,
            headIndexETag: { [s3] in try await s3.headObject(key: TideS3Client.indexKey)?.etag },
            signal: { FileProviderController.signalRemoteChanges() },
            // 拡張 OFF = 全同期停止の検出（Issue #82）。メニューバーアイコンへ反映される。
            isFPDomainEnabled: { await FileProviderController.isEnabled() }
        )
        self.signaler = signaler
        signaler.start()
        AppLogger.ui.info("Launched in FP-only mode (RemoteChangeSignaler active)")

        Self.enforceTLSBucketPolicyDetached(s3: s3)
    }

    /// fpOnly 稼働中の「S3 内復元」サービス（M5 Track B-2）。folderSync（engine 稼働）では
    /// 既存のローカル書き戻し復元（`SyncEngine.restore`）を使うため nil を返す。
    /// tmp は Caches 側のみ（DB / syncRoot / bookmark 非接触 = fpOnly の凍結温存を維持）。
    func makeS3RestoreService() -> S3RestoreService? {
        guard engine == nil, signaler != nil, let s3 else { return nil }
        guard let tmpDir = try? TideTmpDirectory.cacheTmp() else { return nil }
        let updater = ManifestUpdater(
            store: s3,
            deviceId: config.deviceId,
            // 復元の書込確定点で FP レプリカへ即時 signal（アプリ Uploader の onManifestWrite と
            // 同じ配線・coalesce は FileProviderController 側）。定期 HEAD の次周期を待たず反映される。
            onManifestDidWrite: { Task { @MainActor in FileProviderController.signalRemoteChanges() } }
        )
        return S3RestoreService(
            client: s3,
            put: s3,
            updater: updater,
            tmpDir: tmpDir,
            uploadSizeLimitBytes: config.uploadSizeLimitBytes,
            downloadLimiter: RateLimiter(ratePerSec: Double(config.downloadBandwidthBytesPerSec)),
            uploadLimiter: RateLimiter(ratePerSec: Double(config.uploadBandwidthBytesPerSec))
        )
    }

    /// Sync Activity のログソース（Issue #83）。folderSync = DB（sync_log）/ fpOnly = FP 拡張の
    /// 共有イベントログ（`FPEventLog` を読むだけ・DB / syncRoot 非接触 = 凍結温存を維持）。
    /// 未セットアップ（どちらも無し）は nil = ウィンドウはセットアップ誘導表示。
    /// fpOnly の URL 構築失敗（group container 不達のエッジ）は nil にせず fileURL nil の
    /// 縮退ソースを返す — nil だと「Run setup first…」表示になりセットアップ済みユーザへの
    /// 誤誘導になる（PR #90 レビュー nit 4）。縮退時は空表示（No activity yet.）に落ちる。
    func makeSyncActivitySource() -> (any SyncActivitySource)? {
        if let database {
            return DatabaseActivitySource(db: database)
        }
        if signaler != nil, let bucket = config.bucketName, !bucket.isEmpty {
            return FPEventLogActivitySource(
                log: FPEventLog(bucket: bucket, fileURL: try? FPEventLog.defaultURL()))
        }
        return nil
    }

    /// Keychain から AWS 資格情報を読む（folderSync / fpOnly 両起動パス共通）。
    private func loadCredentialsOrThrow() throws -> AWSCredentials {
        do {
            guard let loaded = try keychain.load() else {
                throw SyncError.notConfigured(reason: "AWS credentials not found in Keychain")
            }
            return loaded
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.notConfigured(reason: "Keychain read failed: \(error)")
        }
    }

    /// 既存バケット / ドリフトの自己修復（C3 後半・Issue #26 / B）: 起動ごとに TLS 強制バケットポリシーを
    /// 冪等・非致命で適用する。既に同内容なら GET だけで put しない。起動を遅らせないよう detached、失敗は
    /// ログのみ（多層防御＝Tide 自身の通信は SDK が常に HTTPS。守るのは他ツールの HTTP アクセス）。
    /// folderSync / fpOnly 両起動パスから呼ぶ。
    private static func enforceTLSBucketPolicyDetached(s3: TideS3Client) {
        Task.detached { [s3] in
            do {
                switch try await s3.enforceTLSBucketPolicy() {
                case .updated:
                    AppLogger.s3.info("Enforced HTTPS-only bucket policy on launch")
                case .checkDenied:
                    // 恒常的な IAM 構成（s3:GetBucketPolicy なし）由来で毎起動再発するため error に
                    // しない（ノイズ床対策・Issue #81）。適用状態は検証不能だが多層防御なので非致命。
                    AppLogger.s3.notice("enforceTLSBucketPolicy check skipped on launch: access denied (likely missing s3:GetBucketPolicy; non-fatal, policy state unverified)")
                case .alreadyEnforced:
                    break
                }
            } catch {
                AppLogger.s3.error("enforceTLSBucketPolicy on launch failed (non-fatal): \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// 同期フォルダへの security-scoped アクセスを確立して実 URL を返す（App Sandbox・M5 Phase 2）。
    /// 1) 保存済み bookmark を解決（stale なら再発行）→ 2) 欠落/失効なら再許可パネル。
    /// 受け入れ判定はパス文字列の等値ではなく**ファイル同一性**で行う（PR #49 レビュー #2）:
    /// bookmark はファイル ID でフォルダを追跡するため、Finder でのリネーム/移動後も解決できる。
    /// これをパス不一致として捨てると「満たせない再許可パネル」が毎起動出続け、同期が永久に止まる。
    private func resolveSyncRootAccess(rootPath: String) async throws -> URL {
        let expected = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL

        // 再入（bootstrap リトライ / ウィザード再設定）: 同じフォルダなら確立済みアクセスを使い回す。
        // フォルダが変わっていたら古いアクセスを手放してから取り直す。
        if let current = accessedSyncRootURL {
            if current.standardizedFileURL.path == expected.path
                || PathValidator.isSameFileSystemObject(current, expected) {
                return current
            }
            current.stopAccessingSecurityScopedResource()
            accessedSyncRootURL = nil
        }

        if let data = config.syncRootBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() {
                // 解決できた＝セットアップ時に許可したのと同一実体のフォルダ（bookmark と
                // syncRootPath は completeSetup が常に対で更新するため、乖離は外部リネーム由来）。
                // パスが変わっていたら設定を新パスへ追随させる。
                if url.standardizedFileURL.path != expected.path {
                    AppLogger.ui.info("Sync root was renamed/moved; following it via bookmark and updating the configured path")
                    config.syncRootPath = url.path
                }
                if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
                    config.syncRootBookmark = fresh
                }
                accessedSyncRootURL = url
                return url
            }
        }

        let url = try await requestSyncRootAccessViaPanel(expected: expected)
        accessedSyncRootURL = url
        return url
    }

    /// bookmark 欠落/失効時の一度きり再許可導線: 現行フォルダを初期位置にした NSOpenPanel を出し、
    /// 同じフォルダの選択で bookmark を再発行する。キャンセル/別フォルダ選択は throw して
    /// bootstrapFailure に載せる（ポップオーバーを開き直せば bootstrap 経由で再試行できる）。
    private func requestSyncRootAccessViaPanel(expected: URL) async throws -> URL {
        // LSUIElement アプリはフォアグラウンドに居ないとパネルが見えないまま開く（CLAUDE.md §3 の作法）
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = expected
        panel.message = String(localized: "Tide needs access to the sync folder again. Select the folder shown to continue syncing.")
        panel.prompt = String(localized: "Grant Access")
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let chosen = panel.url else {
            throw SyncError.notConfigured(reason: "Sync folder access was not granted: \(expected.path)")
        }
        // 設定済みフォルダと「同一実体」かで受け入れ判定する（PR #49 レビュー #2）。
        // パス文字列の等値だと、symlink を含む保存パス等で正しいフォルダの選択まで拒否してしまう。
        // 逆に同一性を確認できない別フォルダを黙って受けると、既存 DB との突き合わせで
        // 大量の「ローカル削除」誤検出（＝リモート削除の伝播）を起こしうるので拒否する。
        // 設定パスが既に存在しない（リネーム済みかつ bookmark も失効の二重障害）場合も
        // 同一性を確認できないのでここに落ちる — フォルダ名を戻すかウィザード再設定で復旧。
        guard PathValidator.isSameFileSystemObject(chosen, expected) else {
            throw SyncError.notConfigured(
                reason: "Selected folder is not the configured sync folder (\(expected.path)). "
                    + "If the folder was renamed or moved, rename it back or run setup again.")
        }
        // 同一実体でも表記が違うことはある（symlink 経由の旧保存パス等）— 以後の突き合わせが
        // ブレないよう、実際に許可された表記へ設定を揃える。
        if chosen.standardizedFileURL.path != expected.path {
            config.syncRootPath = chosen.path
        }
        // パネル選択でこのセッションのアクセスは既に得ているが、以後の起動のために bookmark を
        // 発行し、それを解決した URL で scoped アクセスを開始する（保存済み bookmark 経路と同じ形に揃える）。
        let bookmark = try chosen.bookmarkData(options: [.withSecurityScope])
        config.syncRootBookmark = bookmark
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        guard resolved.startAccessingSecurityScopedResource() else {
            throw SyncError.notConfigured(reason: "Could not start scoped access to: \(resolved.path)")
        }
        return resolved
    }

    /// セットアップウィザード完了時に呼ぶ。
    func completeSetup(
        credentials: AWSCredentials,
        bucket: String,
        region: String,
        syncRootPath: String
    ) async throws {
        // App Sandbox 下で以後の起動でも同期フォルダへアクセスできるよう、確定前に
        // security-scoped bookmark を発行する（ウィザードの Choose… パネルで選択済みなら成立）。
        // 手入力パス等でアクセス権が無ければここで失敗し、setupCompleted を立てる前に中断する。
        // NOTE（v0.3.0 過渡・#96〜#97）: fpOnly boot はこの bookmark を使わない。#97（ウィザード
        // fpOnly ネイティブ化）で bookmark 発行・フォルダ選択ステップごと削除予定（docs/09）。
        let syncRootURL = URL(fileURLWithPath: syncRootPath, isDirectory: true)
        let bookmark: Data
        do {
            bookmark = try syncRootURL.bookmarkData(options: [.withSecurityScope])
        } catch {
            throw SyncError.invalidSyncRoot(
                "cannot access the folder (select it with the Choose… button): \(error)")
        }

        try keychain.save(credentials)
        config.bucketName = bucket
        config.region = region
        config.syncRootPath = syncRootPath
        config.syncRootBookmark = bookmark
        // v0.3.0（#96・PR #100 レビュー指摘 2 = #97 二重化の前倒し）: factoryReset がキーを
        // 一時削除した後、同一セッションの再セットアップは bootstrap の正規化書込（起動時のみ）を
        // 通らないため、次回起動まで syncMode 不在 = soak の DB 凍結見張りが静かに非武装のままに
        // なる。ここで明示的に書いて不在窓を閉じる。
        config.syncMode = .fpOnly
        config.setupCompleted = true

        // 二重起動防止（PR #7 レビュー Low）: setupCompleted を立てた後の seed/launch の await 中に、
        // ポップオーバーから走る MenuBarContent.task → bootstrap() が engine==nil で通過して
        // 2 つ目の SyncEngine を起動するのを防ぐ（bootstrap() は isBootstrapping を見て即 return する）。
        isBootstrapping = true
        defer { isBootstrapping = false }

        // 新規バケットのときだけ既定 .syncignore を置く（既存バケット参加時は競合回避のため作らない）
        // NOTE（v0.3.0 過渡・#96〜#97）: seed は**ローカル同期フォルダ**へ書くため、fpOnly boot に
        // なった今は誰も読まず S3 マニフェストへ届かない（新規バケットが既定 ignore を持たない）。
        // #97 で S3 直書き（`files/.syncignore` PUT + ManifestUpdater 合流）へ変更予定（docs/09）。
        // 過渡期間は再セットアップ自体を禁止（Issue #96 運用注意）。
        let syncRoot = URL(fileURLWithPath: syncRootPath, isDirectory: true)
        await Self.seedDefaultSyncIgnoreIfNewBucket(
            credentials: credentials, bucket: bucket, region: region,
            deviceId: config.deviceId, syncRoot: syncRoot
        )

        try await launchEngineFromCurrentConfig()
        // 復旧成功＝失敗状態を解消（PR #7 レビュー Medium）。これ以降は engine != nil 経路でも維持される。
        bootstrapFailure = nil
    }

    /// ローカルに `.syncignore` が無く、かつリモートにマニフェストも無い（＝まだ誰も同期していない
    /// 新規バケット）ときだけ、既定の除外テンプレートを `<syncRoot>/.syncignore` に書く。
    /// 既存バケットに参加する場合は他デバイスの `.syncignore` と競合する恐れがあるので作らない。
    /// 失敗しても致命的ではない（同期は続行）。
    private static func seedDefaultSyncIgnoreIfNewBucket(
        credentials: AWSCredentials, bucket: String, region: String,
        deviceId: String, syncRoot: URL
    ) async {
        do {
            let localURL = try PathValidator.resolveSafely(relativePath: ".syncignore", syncRoot: syncRoot)
            // ローカルに既にあれば触らない（symlink も「ある」扱い）
            if FileManager.default.fileExists(atPath: localURL.path) { return }

            let s3 = try TideS3Client(
                credentials: credentials, region: region, bucket: bucket, deviceId: deviceId
            )
            // リモートにマニフェストがあれば既存バケット → 作らない
            if try await s3.getIndex() != nil { return }

            try SyncIgnoreMatcher.defaultTemplate.write(to: localURL, atomically: true, encoding: .utf8)
            AppLogger.sync.info("Seeded default .syncignore for new bucket")
        } catch {
            AppLogger.sync.error("Failed to seed default .syncignore: \(String(describing: error), privacy: .private)")
        }
    }

    func factoryReset() async {
        await engine?.stop()
        engine = nil
        signaler?.stop()
        signaler = nil
        s3 = nil
        database = nil

        // File Provider ドメインも外す（残すと CloudStorage 側に空ドメインが孤児化する）
        try? await FileProviderController.disable()

        // App Group コンテナ配下の DB ファイル一式（M5 Phase 2 以降の正位置）
        if let groupSupport = try? TideAppGroup.supportDirectoryURL() {
            try? FileManager.default.removeItem(at: groupSupport)
        }
        // App Group コンテナ内 Caches（M5 Phase 4 の File Provider 世代ログ等の派生データ）
        if let groupCaches = try? TideAppGroup.cachesDirectoryURL() {
            try? FileManager.default.removeItem(at: groupCaches)
        }
        // 既知の移行元（旧 group コンテナ / 実ホーム + standard defaults）は LegacyStateMigrator と
        // **同じ定義**を回して掃除する（残すと次回 bootstrap の移行が消したはずの状態を復活させる。
        // 定義の手作業複製は移行元追加時の追随漏れの温床 — PR #50 レビュー #8 で一元化）。
        // 注意: sandbox 下では実ホーム分がコンテナ内に解決され、旧残置分（pre-sandbox の db.sqlite 等）
        // には届かない（完全削除は `make reset` のみ — PR #49 レビュー #5）。standard defaults の消去は
        // OS がコンテナへ自動移行してきた旧 plist の掃除としても効く（設定復活の防止自体は
        // legacy DB 実在ゲートが構造的に担う多層防御）。
        for source in LegacyStateMigrator.productionLegacySources() {
            try? FileManager.default.removeItem(at: source.supportTideDir)
            ConfigStore(defaults: source.defaults).resetIncludingDeviceId()
        }
        // Caches（sandbox 下ではコンテナ内 = ダウンロード tmp / 削除一覧キャッシュ）
        if let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent("Tide"))
        }

        config.resetIncludingDeviceId()
        try? keychain.delete()
        bootstrapFailure = nil
    }
}

extension ProcessInfo {
    /// XCTest 実行中か。テストは本体アプリ（Tide.app）をテストホストとして起動するため、
    /// この判定で eager bootstrap を抑止し、テスト中に実 S3 と同期しないようにする。
    /// `XCTestConfigurationFilePath` は XCTest が起動時に必ずセットする（XCTest をリンク不要）。
    var isRunningXCTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
