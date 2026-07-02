import Foundation
import TideCore

/// FileProvider の observer / completion handler のような「どのスレッドから呼んでも良い契約だが
/// Sendable 注釈が無い」値を Task へ運ぶための箱。
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// 拡張プロセスの依存一式。App Group 共有の設定（group defaults）と Keychain（共有 access group）
/// から構築する。**DB には触らない**（Phase 3 の不変条件）。
struct ExtensionServices: Sendable {
    let s3: TideS3Client
    let cache: ManifestTreeCache

    /// 共有設定から構築する。未セットアップ / 認証情報なしなら nil
    /// （呼び出し側が `NSFileProviderError(.notAuthenticated)` に落とす）。
    /// ログは診断のため既定レベル以上（notice/error = 永続）で出す — 拡張プロセスは
    /// 対話デバッグしづらく、`log show` で追えることが重要（Phase 3 実機デバッグの教訓）。
    static func fromSharedConfig() -> ExtensionServices? {
        let config = ConfigStore()  // 既定 = App Group 共有 suite
        let hasBucket = !(config.bucketName ?? "").isEmpty
        let hasRegion = !(config.region ?? "").isEmpty
        AppLogger.fileProvider.notice("Extension config check: setupCompleted=\(config.setupCompleted) bucket=\(hasBucket) region=\(hasRegion)")
        guard config.setupCompleted, hasBucket, hasRegion,
              let bucket = config.bucketName, let region = config.region else {
            AppLogger.fileProvider.notice("Extension not configured (setup incomplete)")
            return nil
        }
        let credentials: AWSCredentials?
        do {
            credentials = try KeychainStore().load()
        } catch {
            AppLogger.fileProvider.error("Extension: Keychain read failed: \(String(describing: error), privacy: .private)")
            return nil
        }
        guard let credentials else {
            AppLogger.fileProvider.error("Extension: AWS credentials not found in shared Keychain")
            return nil
        }
        do {
            let s3 = try TideS3Client(
                credentials: credentials, region: region, bucket: bucket,
                deviceId: config.deviceId
            )
            return ExtensionServices(
                s3: s3,
                cache: ManifestTreeCache(loader: ManifestSnapshotLoader(source: s3))
            )
        } catch {
            AppLogger.fileProvider.error("Extension: failed to construct S3 client: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}

/// マニフェストスナップショット（→ `ManifestTree`）の短期キャッシュ。
/// 列挙は item / enumerator から細かく呼ばれるので、TTL 内は同じツリーを返して
/// S3 への index/シャード GET を抑える。書込ゼロ・プロセス内メモリのみ。
actor ManifestTreeCache {
    private let loader: ManifestSnapshotLoader
    private let maxAge: TimeInterval
    private var cached: (tree: ManifestTree, fetchedAt: Date)?

    init(loader: ManifestSnapshotLoader, maxAge: TimeInterval = 30) {
        self.loader = loader
        self.maxAge = maxAge
    }

    func tree() async throws -> ManifestTree {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return cached.tree
        }
        let tree = ManifestTree(files: try await loader.load())
        cached = (tree, Date())
        return tree
    }
}
