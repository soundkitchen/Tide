import Foundation
import Observation

/// 依存性注入用のコンテナ。アプリ全体で 1 つ。
@MainActor
@Observable
final class AppEnvironment {
    let config: ConfigStore
    let keychain: KeychainStore

    var database: LocalDatabase?
    var s3: TideS3Client?
    var engine: SyncEngine?

    var isSetupCompleted: Bool { config.setupCompleted }

    /// 起動失敗を bootstrap が記録する。UI 側で「ウィザード強制表示」のヒントに使う。
    var bootstrapFailure: String?

    init() {
        self.config = ConfigStore()
        self.keychain = KeychainStore()
    }

    /// アプリ起動時のブートストラップ。設定済みなら SyncEngine を立ち上げる。
    /// 失敗した場合は bootstrapFailure に詳細を書いて UI 側にウィザード再表示を促す。
    func bootstrap() async {
        bootstrapFailure = nil
        guard config.setupCompleted else {
            AppLogger.ui.info("Setup not completed; awaiting wizard.")
            return
        }
        if engine != nil {
            return  // 既に動いている
        }
        do {
            try await launchEngineFromCurrentConfig()
        } catch {
            let detail = String(describing: error)
            AppLogger.ui.error("Bootstrap failed: \(detail, privacy: .private)")
            bootstrapFailure = detail
        }
    }

    func launchEngineFromCurrentConfig() async throws {
        var missing: [String] = []
        if config.bucketName == nil || config.bucketName?.isEmpty == true { missing.append("bucket name") }
        if config.region == nil || config.region?.isEmpty == true { missing.append("region") }
        if config.syncRootPath == nil || config.syncRootPath?.isEmpty == true { missing.append("sync folder") }
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
            pollIntervalSeconds: config.pollingIntervalSeconds
        )
        self.database = db
        self.s3 = s3
        self.engine = engine
        await engine.start()
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
        try await launchEngineFromCurrentConfig()
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
