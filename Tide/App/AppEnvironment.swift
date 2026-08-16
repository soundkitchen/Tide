import TideCore
import AppKit
import CryptoKit
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

    /// ライフサイクル操作（bootstrap の起動 / completeSetup / factoryReset / FP ドメインの
    /// Enable・Disable）の単一非再入ゲート（PR #101 九次レビュー指摘 2 — 旧 `isBootstrapping` の
    /// bool 1 個は「起動中」と「ドメイン変更 mutex」の二役を兼ねて誤拒否 / 無音ドロップを生んだ）。
    /// 取得セマンティクスは呼び出し元の意味で使い分ける:
    /// - bootstrap = `tryAcquire`（busy なら黙って引く — 他者がライフサイクルを管理中。
    ///   次のポップオーバー再訪で再試行される）
    /// - completeSetup = `acquire`（FIFO 待ち — 進行中の bootstrap 起動や Enable の完了を待って
    ///   から実行して意味が変わらない）
    /// - factoryReset / Enable・Disable = `tryAcquire`（busy なら**拒否** — 待たせて後から実行
    ///   すると意味が変わる: リセット完走後の add 着地 = 全消し済みアプリへのドメイン復活等）
    @ObservationIgnored private let setupGate = RemoteOpGate()

    /// bootstrap が fire-and-forget で走らせる FP ドメイン移行タスク
    /// （`migrateStaleDomainsIfNeeded`）のハンドル。completeSetup がドメイン作り直し
    /// （`disableForRecreation`）の前に await して直列化する — 非直列だと除去前スナップショットで
    /// resume した migrate が pending-add フラグを誤回収 / 旧設定のまま re-add し得る
    /// （PR #101 四次レビュー指摘 3）。
    /// **不変条件（十次レビュー指摘 5）**: spawn は bootstrap のみ・setupGate 保持下・
    /// `migrationTask == nil` のときだけ。drain も全呼び出し元がゲート保持中。この 2 点により
    /// 「drain の await 中に新タスクが spawn される」は構造的に不可能で、世代検査は不要
    /// （旧 `migrationGeneration` は証明可能に不活性のため削除済み — ゲート外の spawn / drain を
    /// 足す変更こそがレビューで弾くべき対象）。
    @ObservationIgnored private var migrationTask: Task<Void, Never>?

    /// FP ドメイン状態の変更通知カウンタ（PR #101 四次レビュー指摘 4）: completeSetup が
    /// `enable()` / `disableForRecreation()` でドメイン状態を変えるため、開きっぱなしの
    /// Settings ウィンドウが `.task(id:)` で再取得できるよう、completeSetup の終了時
    /// （成否問わず = 途中 throw でも disable 済みの可能性がある）にインクリメントする。
    private(set) var fileProviderStateVersion = 0

    /// factoryReset 実行の通知カウンタ（Issue #102）: 開きっぱなしのセットアップウィザードが
    /// これを observe して自窓を閉じ、`@State`（旧セッションの done 画面 / 入力値）を破棄する。
    /// 単一・常駐の `Window` scene はウィンドウを閉じても view と `@State` が生存するため、
    /// env 側からの明示通知がリセット済みアプリへの唯一の到達手段。
    private(set) var setupWizardResetVersion = 0

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
    /// 他のライフサイクル操作進行中（`setupGate` busy）なら bootstrapFailure を触らず即 return。
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
        guard setupGate.tryAcquire() else {
            // 起動処理 / completeSetup / factoryReset / Enable・Disable 進行中
            // （bootstrapFailure は触らない＝進行中の操作に委ねる。ポップオーバー再訪で再試行）
            return
        }
        defer { setupGate.release() }
        bootstrapFailure = nil
        // 旧 identifier（PoC 世代）の FP ドメインが残っていれば現行 identifier で作り直す。
        // fire-and-forget（XPC 待ちで起動をブロックしない）・no-op が定常。ハンドルは保持し、
        // completeSetup / factoryReset がドメインを変える前に await して直列化する（四次レビュー
        // 指摘 3 / 六次レビュー指摘 4）。**実行中はハンドルを再利用**（同時 1 本 = 孤児を作らない・
        // 五次レビュー指摘 1）し、**完了時に自己解放**して次回 bootstrap の新規 spawn（再試行）を
        // 許す — 五次のチェーン方式は未セットアップ中のポップオーバー再訪ごとにタスクが無限連鎖し、
        // completeSetup がチェーン全長を await する問題があった（六次レビュー指摘 5）。
        if migrationTask == nil {
            migrationTask = Task {
                await FileProviderController.migrateStaleDomainsIfNeeded()
                // 自己解放（完了時に次回 bootstrap の新規 spawn = 再試行を許す）。spawn/drain が
                // 全てゲート下にある不変条件（migrationTask の doc）により、この nil が別タスクの
                // ハンドルを指すことはない — 同時に存在するタスクは常に最大 1 本。
                self.migrationTask = nil
            }
        }
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

        // FP ドメインが有効でなければ signal は向こうの status ガードで no-op になる（起動自体は
        // 続行 = Enable / システム設定で ON にすれば次の契機から効き始める）。気づけるようログだけ
        // 残す（定常の可視化は signaler の毎周回観測が担う・#82/#103）。
        let initialStatus = await FileProviderController.domainStatus()
        if initialStatus != .enabled {
            AppLogger.ui.info("FP-only mode: File Provider domain is not active (status: \(String(describing: initialStatus), privacy: .public)); syncing is paused until it is enabled")
        }
        // stale な「Tide is not syncing」通知の掃除は**無条件**（#103 受け入れ 2026-08-16 で発見・
        // 無条件化は PR #109 再レビュー指摘）: 復帰がウィザード（completeSetup）経由だと signaler
        // がここで作り直されるため、無効状態を保持していた旧 signaler の復帰エッジ（撤去の通常
        // 経路）が発火しない。アプリ再起動をまたいだ復帰も同様。enabled 限定だと取得失敗
        // （nil = fileproviderd 無応答）の起動で漏れ、以後の通常経路でも回収できない（新 signaler
        // は false 始まりのため enabled 観測はどちらのエッジも成立しない）。撤去は冪等で、本当に
        // 無効な起動でも直後の初回 checkOnce が無効エッジで同一 identifier の通知を再発行する
        // （従来から毎起動で置換再発行）ため、可視挙動は退行しない。
        notifications.removeDelivered(
            identifier: NotificationPolicy.content(for: .fileProviderDisabled).identifier)

        let signaler = RemoteChangeSignaler(
            intervalSeconds: config.pollingIntervalSeconds,
            headIndexETag: { [s3] in try await s3.headObject(key: TideS3Client.indexKey)?.etag },
            signal: { FileProviderController.signalRemoteChanges() },
            // 拡張 OFF = 全同期停止の検出（Issue #82 / #103）。メニューバーアイコンへ反映される。
            // 判定は userEnabled 込みの domainStatus() — 掲載有無だけではシステム設定のトグル OFF
            // を検出できない（現 OS では domains() に載ったまま userEnabled=false になる・#103
            // 実機実証 2026-08-15）。取得失敗（nil）は無効側に倒す = 従来挙動の維持
            // （毎周回の再観測で自己回復する・見逃しは ETag 変化まで気づけない）。
            isFPDomainEnabled: { await FileProviderController.domainStatus() == .enabled },
            // 無効/復帰エッジで OS 通知を発火/撤去（Issue #103・通知 5 事象目 =「ユーザ介入が要る
            // 確定的な全同期停止」。エッジ検出のみ = 連発しない・identifier 固定で万一も置換）。
            onFPDomainDisabledEdge: { [weak self, notifications] disabled in
                let identifier = NotificationPolicy.content(for: .fileProviderDisabled).identifier
                if disabled {
                    Task { @MainActor in
                        await notifications.post(.fileProviderDisabled)
                        // post は許可プロンプト応答待ち等で長く suspend し得る（初回は分単位も
                        // あり得る）。その間に復帰エッジが来ると撤去（下の分岐）が**未配達で
                        // no-op** になり、後から配達された stale 通知が残る（PR #109 レビュー
                        // 指摘 1）。配達後に現在の観測を再読し、もう無効でなければ即撤去する
                        // （signaler 不在 = factoryReset 後も撤去側。撤去は冪等）。
                        if self?.signaler?.fpDomainDisabled != true {
                            notifications.removeDelivered(identifier: identifier)
                        }
                    }
                } else {
                    notifications.removeDelivered(identifier: identifier)
                }
            }
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
        let updater = Self.makeSignalingManifestUpdater(store: s3, deviceId: config.deviceId)
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

    /// FP ドメインを変える操作の前に、bootstrap の fire-and-forget migrate を必ず飲み干す共通
    /// チョークポイント（四次レビュー指摘 3 で導入・七次レビュー指摘 3 で 3 変更点へ統一）:
    /// completeSetup / factoryReset / Settings の Enable/Disable のいずれも、in-flight の migrate が
    /// stale スナップショットで resume してドメイン変更と交錯（pending-add フラグ誤回収 / 孤児
    /// re-add）しないよう、変更前にここを通す。
    /// **必ず setupGate 保持中に呼ぶこと**（十次レビュー指摘 5 — spawn も bootstrap のゲート下
    /// のみ、という対の不変条件が「await 中の新規 spawn」を構造的に排除しており、無条件 nil が
    /// 安全なのはそのため。ゲート外の呼び出し元を足すならこの前提ごと再設計する）。
    private func drainDomainMigration() async {
        await migrationTask?.value
        migrationTask = nil
    }

    /// Enable/Disable ラッパ共通の choreography（十次レビュー指摘 6 で集約）: tryAcquire 拒否 →
    /// defer release → defer 変更カウンタバンプ → migrate ドレイン → 本体。**第 3 のドメイン操作
    /// 導線は必ずここを通すこと** — 手コピーで drain かバンプを落とすと、本 PR のレビューで
    /// 閉じてきた migrate/XPC race・stale 表示が再開する。他のライフサイクル操作の進行中は
    /// **拒否**（`tryAcquire`）— 待たせて後から実行すると意味が変わる（リセット完走後に add が
    /// 着地 = 全消し済みアプリへのドメイン復活。次回起動の migrate は staleDomains 空 ×
    /// フラグ無しで即 return するため自己修復も効かない）。
    private func withDomainLifecycleGate(_ op: () async throws -> Void) async throws {
        guard setupGate.tryAcquire() else {
            throw SyncError.notConfigured(reason: "another operation is in progress (startup, setup, or reset); try again in a moment")
        }
        defer { setupGate.release() }
        defer { fileProviderStateVersion += 1 }
        await drainDomainMigration()
        try await op()
    }

    /// Settings の Enable ボタン用ラッパ（七次レビュー指摘 3 / 八次レビュー指摘 2・6 / 九次
    /// レビュー指摘 2・6）。未セットアップ時は拒否（九次レビュー指摘 6 — config 無しでドメインを
    /// 作ると拡張が未設定エラー列挙になり、後のウィザードに偽の破壊警告まで出す）。
    /// View から素の FileProviderController.enable() を直接叩かないこと。
    func enableFileProviderDomain() async throws {
        guard config.setupCompleted else {
            throw SyncError.notConfigured(reason: "run setup first — the File Provider domain needs a configured bucket")
        }
        try await withDomainLifecycleGate { try await FileProviderController.enable() }
    }

    /// Settings の Disable ボタン用ラッパ（enable 側と対）。**setupCompleted は要求しない** —
    /// ドメイン除去は未設定アプリでも常に安全で、「全消し済みアプリに生き残ったドメイン」の
    /// 手動回復導線として機能する必要がある。
    func disableFileProviderDomain() async throws {
        try await withDomainLifecycleGate { try await FileProviderController.disable() }
    }

    /// FP ドメインを作り直すか + その判定に使ったドメイン有効状態、を**単一 probe** で返す。
    /// `recreate` は **completeSetup の実行判定とウィザード fileProvider ステップの警告表示が
    /// 共有する単一判定**（五次レビュー指摘 2 — 複製すると枝の増減に UI が追従できない）。
    /// 判定は config 上書き**前**の旧 bucketName で行う不変条件（completeSetup 内コメント参照）。
    /// `enabled` を同一スナップショットで併せて返すのは、ウィザードの警告/緑チェックが異時点の
    /// 2 スナップショット合成で矛盾表示にならないため（七次レビュー指摘 5。isEnabled の XPC も
    /// 1 往復に畳まれる）。
    func probeDomainRecreation(forBucket bucket: String) async -> (recreate: Bool, status: FileProviderController.DomainStatus?) {
        // 作り直し判定に要るのは**登録有無**: userDisabled のドメインもレプリカ実在 = 登録済みと
        // して扱う（#103）。status を生のまま返すのは、ウィザードが userDisabled の事前警告に
        // 使うため（PR #109 レビュー指摘 2 — 追加 XPC ゼロ・単一スナップショット維持）。
        let status = await FileProviderController.domainStatus()
        if let previousBucket = config.bucketName, !previousBucket.isEmpty {
            // 既知の旧バケット: 変わったときだけ作り直す。同一バケットの再セットアップ
            // （クリーンインストール復旧 / 認証情報の再設定）はレプリカ温存（再 add no-op）。
            return (recreate: previousBucket != bucket, status: status)
        }
        // bucketName 不在 = factoryReset がキーを消した後（disable 失敗の握りつぶし〈try?〉も
        // 通過し得る）。生存ドメインがあってもレプリカの素性（どのバケット由来か）を保証
        // できないため作り直す（再レビュー指摘 3）。既知の未登録（.notRegistered = 通常の
        // クリーンセットアップ）のみスキップし、不明（nil）は作り直し側に倒す — 温存側に倒すと
        // 「domainStatus 失敗 → 直後の enable 成功」の並びで素性不明レプリカが残る。
        return (recreate: status != .notRegistered, status: status)
    }

    /// 書込確定点で FP レプリカへ即時 signal する配線付き `ManifestUpdater`（S3 内復元 / seed 共用・
    /// PR #101 レビュー指摘 2）。アプリ Uploader の onManifestWrite と同じ配線・coalesce は
    /// FileProviderController 側。定期 HEAD の次周期を待たず反映される。構築をここへ寄せ、
    /// 呼び出し側ごとの手書き配線による signal 漏れ（PR #56 レビュー ④ の警戒）を構造的に防ぐ。
    private static func makeSignalingManifestUpdater(
        store: any ManifestStore, deviceId: String
    ) -> ManifestUpdater {
        ManifestUpdater(
            store: store,
            deviceId: deviceId,
            onManifestDidWrite: { Task { @MainActor in FileProviderController.signalRemoteChanges() } }
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

    /// セットアップウィザード完了時に呼ぶ（#97・fpOnly ネイティブ）。同期の実体は FP レプリカのみで
    /// ローカル同期フォルダは存在しないため、security-scoped bookmark の発行・`syncRootPath` /
    /// `syncRootBookmark` の書込は行わない。順序が本質: **旧 signaler 停止 → ドメイン作り直し判定 →
    /// config/Keychain 保存 → seed → FP enable → signaler 起動**。保存前に enable すると拡張が
    /// 未設定状態で起動してエラー列挙になり、enable 後に seed の新規バケット判定を置くと拡張の
    /// 先行書込で誤判定し得る（docs/09 v0.3.0 節・PR #101 再レビュー指摘 4）。
    func completeSetup(
        credentials: AWSCredentials,
        bucket: String,
        region: String
    ) async throws {
        // v0.3.0（#96・PR #100 レビュー指摘 2 = #97 二重化）: factoryReset がキーを
        // 一時削除した後、同一セッションの再セットアップは bootstrap の正規化書込（起動時のみ）を
        // 通らないため、書かないと次回起動まで syncMode 不在 = soak の DB 凍結見張りが静かに
        // 非武装のままになる。**throw し得る処理（Keychain 保存 / FP enable）より前**に書く —
        // 途中失敗でも不在窓を無条件に閉じるため（冪等・他に依存しない。再レビュー指摘 3）。
        config.syncMode = .fpOnly

        // ライフサイクルゲート取得（九次レビュー指摘 2）: FIFO 待ち（`acquire`）— 進行中の
        // bootstrap 起動（低速ネットワークで数十秒かかり得る）や Enable/Disable の完了を**待って
        // から**実行して意味が変わらないため、拒否でなく直列化する（旧 isBootstrapping の busy
        // throw は「実際にはセットアップもリセットも走っていない」bootstrap 起動中の誤拒否を
        // 生んでいた）。保持中は bootstrap() が tryAcquire で引く = 二重起動防止（PR #7 レビュー
        // Low）も同じゲートが担う。syncMode 書込は例外的にゲート前（途中失敗でも不在窓を無条件に
        // 閉じる既存不変条件・冪等・sync のため割り込み無し）。
        await setupGate.acquire()
        defer { setupGate.release() }
        // syncMode の**再書込**（十次レビュー指摘 2）: FIFO 待機中にゲート保持側の factoryReset が
        // `resetIncludingDeviceId()` でキーを消し得る。ゲート前の書込は「acquire 前に throw する
        // 経路」への保証として残し、取得後にもう一度書いて「completeSetup が完走したのに保存
        // syncMode 不在」（soak の DB 凍結見張りが次回起動の正規化まで非武装）を塞ぐ（冪等）。
        config.syncMode = .fpOnly
        // FP ドメイン状態は成否を問わず変わり得る（途中 throw でも disableForRecreation 済みの
        // 可能性がある）ため、終了時に必ず通知して開きっぱなしの Settings に再取得させる
        // （四次レビュー指摘 4）。
        defer { fileProviderStateVersion += 1 }

        // 再セットアップ（ウィザード再実行）経路: 旧 signaler を**最初に**止める（PR #101
        // 再レビュー指摘 2）。enable の後ろに置くと enable 失敗時に旧バケット束縛（構築時の
        // `[s3]` キャプチャ）の pollTask が生き残り、bootstrap() の signaler != nil 早期 return +
        // bootstrapFailure クリアで「健康に見えたまま新バケットの signaler が二度と立たない」
        // 状態に固着する。launchEngineFromCurrentConfig は毎回新規構築するため早期 stop に害は
        // ない（途中失敗時は次の bootstrap() が現行 config で立て直す）。初回セットアップは
        // nil = no-op。
        signaler?.stop()
        signaler = nil

        // bootstrap の fire-and-forget 移行タスクと直列化（四次レビュー指摘 3）: in-flight の
        // migrate が除去**前**のスナップショットで resume すると、この後 disableForRecreation が
        // 立てる pending-add フラグを誤回収（stale な hasCurrent=true でフラグ除去）/ 旧設定の
        // ままの re-add をし得る。完了を待ってから進む（cancel では XPC 待ちの本体を止められない）。
        await drainDomainMigration()

        // FP ドメインの作り直し判定（PR #101 レビュー指摘 1 + 再レビュー指摘 3）: `enable()` の
        // 既有効 no-op はレプリカを温存するため、旧バケット由来の保留書込（dirty item）が残ると
        // 拡張（書込時に共有 config から bucket を読む = `ExtensionServices.fromSharedConfig`）の
        // 再試行がそれらを**新バケットへ**静かに混入させる。disable はドメインごと保留書込を
        // 破棄する（PR #61 記録）が、旧バケットの内容を新バケットへ流すより安全側。判定は
        // config 上書き**前**の旧値で行い、失敗は config 未更新のまま throw（先に config を書くと
        // 失敗後のリトライが「同一バケット」に見えて作り直しがスキップされ、混入窓が残る）。
        // 判定本体はウィザードの警告表示と共有（`probeDomainRecreation(forBucket:)`・五次レビュー
        // 指摘 2 / 七次レビュー指摘 5）。ここでは recreate 側だけ使う。
        let needsDomainRecreation = await probeDomainRecreation(forBucket: bucket).recreate
        if needsDomainRecreation {
            AppLogger.ui.info("Recreating File Provider domain (bucket switch or unknown replica origin): \(self.config.bucketName ?? "(none)", privacy: .private) -> \(bucket, privacy: .private)")
            // disableForRecreation は pending-add フラグを立ててから remove する（再レビュー
            // 指摘 1）: この後の Keychain 保存 / enable が throw しても、次回起動の
            // migrateStaleDomainsIfNeeded が add を再開する = 無音の同期停止にならない。
            try await FileProviderController.disableForRecreation()
        }

        try keychain.save(credentials)
        config.bucketName = bucket
        config.region = region
        config.setupCompleted = true

        // 新規バケットのときだけ既定 .syncignore を S3 へ直接 seed（既存バケット参加時は作らない）。
        // enable より**前**に行う（PR #101 再レビュー指摘 4）: 後ろだと live になった拡張の先行
        // createItem が index.json を作り、「新規バケット」判定（getIndex == nil）が誤って既存側に
        // 倒れて seed が無音スキップされ得る。seed は S3 にしか触れず、確定点 signal は未登録
        // ドメインでは no-op（performSignal の domainStatus ガード）・enable 後の初回列挙が entry を拾う。
        await Self.seedDefaultSyncIgnoreIfNewBucket(
            credentials: credentials, bucket: bucket, region: region, deviceId: config.deviceId
        )

        // FP ドメイン有効化（fpOnly の同期実体）。既有効の再 add は成功/no-op。失敗は throw →
        // ウィザードにエラー表示（設定は保存済みなので Settings の Enable ボタンからも回復できる）。
        try await FileProviderController.enable()

        try await launchEngineFromCurrentConfig()
        // 復旧成功＝失敗状態を解消（PR #7 レビュー Medium）。これ以降は signaler != nil 経路でも維持される。
        bootstrapFailure = nil
    }

    /// リモートにマニフェストが無い（＝まだ誰も同期していない新規バケット）ときだけ、既定の除外
    /// テンプレートを S3 の `files/.syncignore` へ直接 PUT し、`ManifestUpdater` の共有チョーク
    /// ポイントで entry を確定する（#97・`S3RestoreService` と同型の書込）。fpOnly にローカル
    /// 同期フォルダは無いため S3 が唯一の書き先。呼び出しは `enable()` より**前**（PR #101
    /// 再レビュー指摘 4 = 拡張の先行書込による新規バケット誤判定の防止）のため確定点 signal は
    /// no-op で、enable 後の初回列挙が entry を拾う（signal 配線は S3 内復元との共用ファクトリ
    /// 由来・未登録ドメインでは guard され無害）。既存バケットに参加する場合は他デバイスの
    /// `.syncignore` と競合する恐れがあるので作らない。失敗しても致命的ではない（同期は続行）。
    private static func seedDefaultSyncIgnoreIfNewBucket(
        credentials: AWSCredentials, bucket: String, region: String, deviceId: String
    ) async {
        do {
            let s3 = try TideS3Client(
                credentials: credentials, region: region, bucket: bucket, deviceId: deviceId
            )
            // リモートにマニフェストがあれば既存バケット → 作らない
            if try await s3.getIndex() != nil { return }

            // index 不在でも shards が生存する「損傷バケット」（外部削除・ライフサイクル事故等）を
            // 新規バケットと誤認しない（八次レビュー指摘 4）: この状態で seed すると、生存シャードに
            // カスタム `.syncignore` があっても PUT が RMW 判定より先に最新版を既定テンプレートへ
            // 置換し、さらに 1 シャードだけ宣言する index を新造して soak-check の index-missing
            // DRIFT を WARN へ格下げしてしまう。プレフィックスに何か（live 版 / delete marker）が
            // 見えたら seed しない（復旧手順は docs/09「損傷バケット」バックログ）。
            let shardsProbe = try await s3.listObjectVersions(prefix: ".tide/shards/", maxKeys: 1)
            guard shardsProbe.versions.isEmpty, shardsProbe.deleteMarkers.isEmpty else {
                AppLogger.sync.notice("Skipping .syncignore seed: index missing but shard objects exist (damaged bucket?)")
                return
            }
            // 逆側の損傷（`.tide/**` だけ失われ `files/` は無傷・九次レビュー指摘 4）も新規バケットと
            // 誤認しない: 生存中のカスタム `files/.syncignore` を既定テンプレートで置換（版履歴には
            // 残るが実効ルールが差し替わる）+ 生存オブジェクト全部をマニフェスト外の孤児にする
            // 1 entry index の新造、を防ぐ。何か見えたら seed しない。
            let filesProbe = try await s3.listObjectVersions(prefix: "files/", maxKeys: 1)
            guard filesProbe.versions.isEmpty, filesProbe.deleteMarkers.isEmpty else {
                AppLogger.sync.notice("Skipping .syncignore seed: manifest missing but files/ objects exist (damaged bucket?)")
                return
            }

            let data = Data(SyncIgnoreMatcher.defaultTemplate.utf8)
            let put = try await s3.putObject(key: "files/.syncignore", data: data)
            let now = ISO8601.now()
            let entry = ManifestFileEntry(
                size: Int64(data.count),
                mtime: now,
                sha256: HashCalculator.hex(SHA256.hash(data: data)),
                s3VersionId: put.versionId,
                etag: put.etag,
                deviceId: deviceId,
                uploadedAt: now
            )
            let updater = makeSignalingManifestUpdater(store: s3, deviceId: deviceId)
            do {
                _ = try await updater.updateFileEntry(for: ".syncignore", base: nil, newEntry: entry)
            } catch {
                // shard 確定 → index 失敗（#91 の indexUpdateFailedAfterCommit 系）をここで
                // 取りこぼすと、shards だけ存在するバケットが残り、次回セットアップの shards
                // probe（上）が「損傷バケット」と判定して seed を**恒久スキップ**する（九次
                // レビュー指摘 3 — 既定除外が無効のまま静かに稼働）。1 回だけ即時リトライ:
                // 再実行は decideUpload の alreadyUpToDate 経路 → repairIndexDeclarationIfStale が
                // index 宣言を治癒する。それでも失敗なら best-effort の範囲（外側 catch でログ）。
                AppLogger.sync.error("Seed manifest write failed; retrying once: \(String(describing: error), privacy: .private)")
                _ = try await updater.updateFileEntry(for: ".syncignore", base: nil, newEntry: entry)
            }
            AppLogger.sync.info("Seeded default .syncignore for new bucket (S3 direct)")
        } catch {
            AppLogger.sync.error("Failed to seed default .syncignore: \(String(describing: error), privacy: .private)")
        }
    }

    /// 実行できなかった場合（他のライフサイクル操作進行中）は false を返す — 呼び出し側は
    /// 成功時のみウィンドウを閉じ、スキップ時はメッセージを出すこと（九次レビュー指摘 1 —
    /// 無言 no-op を「リセット完了」と誤認させない。Mac を手放す前のリセット等で実害）。
    @discardableResult
    func factoryReset() async -> Bool {
        // 相互排他（八次レビュー指摘 2 / 九次レビュー指摘 2 でゲート化）: completeSetup /
        // Enable・Disable / bootstrap 起動の進行中は**拒否**（待たせて後から実行すると相手の
        // enable と自分の全消しが交錯し「全消し済みアプリ + 生きたドメイン」に到達し得る）。
        // ゲート保持中は bootstrap() も tryAcquire で引く = `disable()` の XPC 窓での
        // migrationTask 再 spawn / 消される直前の config・Keychain からの signaler 再起動
        // （七次レビュー指摘 2）も同時に封鎖される。
        guard setupGate.tryAcquire() else {
            AppLogger.ui.notice("factoryReset skipped: another lifecycle operation is in progress")
            return false
        }
        defer { setupGate.release() }
        // bootstrap の fire-and-forget migrate と直列化（六次レビュー指摘 4）: XPC await 中の
        // migrate がリセット完走後に stale スナップショットで resume すると、リセット済みアプリへ
        // 孤児ドメインを re-add / add 失敗時は pending フラグを残置し得る。完了を待ってから壊す。
        await drainDomainMigration()
        // FP ドメイン状態が変わる（disable）ため、開きっぱなしのウィザード / Settings /
        // ポップオーバーへ再取得を促す（六次レビュー指摘 3）。
        defer { fileProviderStateVersion += 1 }
        // 開きっぱなしのウィザード窓（done 出っぱなし等）へ「閉じて状態破棄」を通知する
        // （Issue #102 現象 1 — 通知しないと旧セッションの done 画面が残り続ける）。
        defer { setupWizardResetVersion += 1 }

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
        return true
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
