import TideCore
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
        if engine != nil {
            // 既に動いている＝失敗状態は解消済み。早期 return でも bootstrapFailure をクリアして
            // 旧来の「毎回先頭でクリア」自己修復を温存する。さもないと「失敗→ウィザードで復旧→正常稼働」後も
            // bootstrapFailure が残り、ポップオーバーを開くたびにウィザードが再表示され続ける（PR #7 レビュー Medium）。
            bootstrapFailure = nil
            return
        }
        if isBootstrapping {
            return  // 起動処理進行中（bootstrapFailure は触らない＝進行中の launch に委ねる）
        }
        isBootstrapping = true
        defer { isBootstrapping = false }
        bootstrapFailure = nil
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

        let credentials: AWSCredentials
        do {
            guard let loaded = try keychain.load() else {
                throw SyncError.notConfigured(reason: "AWS credentials not found in Keychain")
            }
            credentials = loaded
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.notConfigured(reason: "Keychain read failed: \(error)")
        }
        let dbURL = try LocalDatabase.defaultURL()
        let db = try LocalDatabase(at: dbURL)
        try db.pruneOldLogs()

        let s3 = try TideS3Client(
            credentials: credentials,
            region: region,
            bucket: bucket,
            deviceId: config.deviceId
        )

        // syncRoot バリデーション
        let url = URL(fileURLWithPath: rootPath, isDirectory: true)
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

        // 既存バケット / ドリフトの自己修復（C3 後半・Issue #26 / B）: 起動ごとに TLS 強制バケットポリシーを
        // 冪等・非致命で適用する。既に同内容なら GET だけで put しない。起動を遅らせないよう detached、失敗は
        // ログのみ（多層防御＝Tide 自身の通信は SDK が常に HTTPS。守るのは他ツールの HTTP アクセス）。
        Task.detached { [s3] in
            do {
                if try await s3.enforceTLSBucketPolicy() == .updated {
                    AppLogger.s3.info("Enforced HTTPS-only bucket policy on launch")
                }
            } catch {
                AppLogger.s3.error("enforceTLSBucketPolicy on launch failed (non-fatal): \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// セットアップウィザード完了時に呼ぶ。
    func completeSetup(
        credentials: AWSCredentials,
        bucket: String,
        region: String,
        syncRootPath: String
    ) async throws {
        try keychain.save(credentials)
        config.bucketName = bucket
        config.region = region
        config.syncRootPath = syncRootPath
        config.setupCompleted = true

        // 二重起動防止（PR #7 レビュー Low）: setupCompleted を立てた後の seed/launch の await 中に、
        // ポップオーバーから走る MenuBarContent.task → bootstrap() が engine==nil で通過して
        // 2 つ目の SyncEngine を起動するのを防ぐ（bootstrap() は isBootstrapping を見て即 return する）。
        isBootstrapping = true
        defer { isBootstrapping = false }

        // 新規バケットのときだけ既定 .syncignore を置く（既存バケット参加時は競合回避のため作らない）
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
        s3 = nil
        database = nil

        // Application Support 配下の DB ファイル一式
        if let supportRoot = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            try? FileManager.default.removeItem(at: supportRoot.appendingPathComponent("Tide"))
        }
        // Caches 配下の tmp / その他
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
