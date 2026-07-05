import FileProvider
import Foundation
import TideCore

/// FileProvider の observer / completion handler のような「どのスレッドから呼んでも良い契約だが
/// Sendable 注釈が無い」値を Task へ運ぶための箱。
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// 拡張プロセスの依存一式。App Group 共有の設定（group defaults）と Keychain（共有 access group）
/// から構築する。**DB には触らない**（Phase 3 からの不変条件。世代ログは App Group Caches の
/// 拡張専用 JSON = GRDB 非接触）。
struct ExtensionServices: Sendable {
    let s3: TideS3Client
    let cache: ManifestGenerationCache
    /// workingSet への自己 signal。機会的自己 signal（`onNewGeneration`）と、kind 変化
    /// 2 相配信のセッション跨ぎ（M5 Phase 5-1: フェーズ 1 の delete 確定後にこれを発火して、
    /// システムに**新しい変更列挙セッション**でフェーズ 2 を取りに来させる）で共用する。
    let signalWorkingSet: @Sendable () -> Void

    /// 共有設定から構築する。未セットアップ / 認証情報なしなら nil
    /// （呼び出し側が `NSFileProviderError(.notAuthenticated)` に落とす）。
    /// ログは診断のため既定レベル以上（notice/error = 永続）で出す — 拡張プロセスは
    /// 対話デバッグしづらく、`log show` で追えることが重要（Phase 3 実機デバッグの教訓）。
    /// - Parameter domain: 機会的自己 signal（キャッシュ更新が新世代 = リモート変化を検知した
    ///   ときの `signalEnumerator(.workingSet)`）の宛先。
    static func fromSharedConfig(domain: NSFileProviderDomain) -> ExtensionServices? {
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
            let logURL = try? ManifestGenerationLog.defaultURL()
            if logURL == nil {
                AppLogger.fileProvider.error("Extension: generation log URL unavailable (persisting disabled)")
            }
            // NSFileProviderDomain は Sendable 注釈が無いが、signalEnumerator は
            // どのスレッド/プロセスから呼んでもよい契約なので箱で closure へ運ぶ。
            let boxedDomain = UncheckedSendableBox(value: domain)
            let signalWorkingSet: @Sendable () -> Void = {
                // replicated 拡張への signal は .workingSet のみ有効（他は無視される）。
                NSFileProviderManager(for: boxedDomain.value)?.signalEnumerator(for: .workingSet) { error in
                    if let error {
                        AppLogger.fileProvider.error("Self-signal failed: \(String(describing: error), privacy: .private)")
                    }
                }
            }
            let cache = ManifestGenerationCache(
                loader: ManifestSnapshotLoader(source: s3),
                bucket: bucket,
                logURL: logURL,
                onNewGeneration: {
                    // ブラウズ契機のリフレッシュがリモート変化に気づいた時の自己 signal。
                    // アプリ側の pull 後 signal が主経路で、これはアプリ非起動時の補完。
                    signalWorkingSet()
                }
            )
            return ExtensionServices(s3: s3, cache: cache, signalWorkingSet: signalWorkingSet)
        } catch {
            AppLogger.fileProvider.error("Extension: failed to construct S3 client: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}
