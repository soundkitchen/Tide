import Foundation

/// アプリ設定の永続化（UserDefaults ベース）。認証情報は別途 KeychainStore。
final class ConfigStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Key {
        static let bucketName = "tide.bucketName"
        static let region = "tide.region"
        static let syncRootPath = "tide.syncRootPath"
        static let deviceId = "tide.deviceId"
        static let pollingIntervalSeconds = "tide.pollingIntervalSeconds"
        static let setupCompleted = "tide.setupCompleted"
        static let uploadSizeLimitBytes = "tide.uploadSizeLimitBytes"
        static let uploadBandwidthBytesPerSec = "tide.uploadBandwidthBytesPerSec"
        static let downloadBandwidthBytesPerSec = "tide.downloadBandwidthBytesPerSec"
        static let notificationsEnabled = "tide.notificationsEnabled"
    }

    /// 1 ファイルあたりのアップロードサイズ上限の既定値（1 GiB）。
    static let defaultUploadSizeLimitBytes: Int64 = 1 * 1024 * 1024 * 1024

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var bucketName: String? {
        get { defaults.string(forKey: Key.bucketName) }
        set { defaults.set(newValue, forKey: Key.bucketName) }
    }

    var region: String? {
        get { defaults.string(forKey: Key.region) }
        set { defaults.set(newValue, forKey: Key.region) }
    }

    var syncRootPath: String? {
        get { defaults.string(forKey: Key.syncRootPath) }
        set { defaults.set(newValue, forKey: Key.syncRootPath) }
    }

    var pollingIntervalSeconds: Int {
        get {
            let v = defaults.integer(forKey: Key.pollingIntervalSeconds)
            return v == 0 ? 180 : v
        }
        set { defaults.set(newValue, forKey: Key.pollingIntervalSeconds) }
    }

    var setupCompleted: Bool {
        get { defaults.bool(forKey: Key.setupCompleted) }
        set { defaults.set(newValue, forKey: Key.setupCompleted) }
    }

    /// 1 ファイルあたりのアップロードサイズ上限（バイト）。
    /// `-1` = 無制限。キー未設定（`0`）のときは既定値（1 GiB）を返す（`pollingIntervalSeconds` と同じ流儀）。
    /// この上限はアップロード方向のみに適用し、ダウンロード（復元）は常に許可する。
    var uploadSizeLimitBytes: Int64 {
        get {
            // キー未設定なら既定値。`0` を「未設定」と「明示的な 0」の両義で使わないよう、
            // presence（`object(forKey:)`）で判定する（-1=無制限などの明示値はそのまま尊重）。
            guard defaults.object(forKey: Key.uploadSizeLimitBytes) != nil else {
                return Self.defaultUploadSizeLimitBytes
            }
            return Int64(defaults.integer(forKey: Key.uploadSizeLimitBytes))
        }
        set { defaults.set(Int(newValue), forKey: Key.uploadSizeLimitBytes) }
    }

    /// アップロードの帯域上限（bytes/sec）。`<= 0` = 無制限。既定（キー未設定）は無制限（`-1`）。
    /// この上限は file 本体の転送（`files/*`）だけに効き、マニフェスト・シャード等の小さな
    /// メタデータ PUT/GET には掛けない。Uploader が周回ごとに読み直して反映する。
    var uploadBandwidthBytesPerSec: Int64 {
        get {
            guard defaults.object(forKey: Key.uploadBandwidthBytesPerSec) != nil else { return -1 }
            return Int64(defaults.integer(forKey: Key.uploadBandwidthBytesPerSec))
        }
        set { defaults.set(Int(newValue), forKey: Key.uploadBandwidthBytesPerSec) }
    }

    /// ダウンロード（復元）の帯域上限（bytes/sec）。`<= 0` = 無制限。既定は無制限（`-1`）。
    var downloadBandwidthBytesPerSec: Int64 {
        get {
            guard defaults.object(forKey: Key.downloadBandwidthBytesPerSec) != nil else { return -1 }
            return Int64(defaults.integer(forKey: Key.downloadBandwidthBytesPerSec))
        }
        set { defaults.set(Int(newValue), forKey: Key.downloadBandwidthBytesPerSec) }
    }

    /// 競合発生・未バックアップ確定（サイズ超過 / give-up / 不安定）を OS 通知で知らせるか。
    /// キー未設定なら既定 on（オプトアウト方式）。実際に通知を出すかは OS の許可状態にも従う。
    var notificationsEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.notificationsEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.notificationsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// 初回アクセス時に UUID を自動生成して保存する。以降不変。
    var deviceId: String {
        if let existing = defaults.string(forKey: Key.deviceId), !existing.isEmpty {
            return existing
        }
        let host = (Host.current().localizedName ?? "Mac")
            .replacingOccurrences(of: " ", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        let id = "\(host)-\(suffix)"
        defaults.set(id, forKey: Key.deviceId)
        return id
    }

    /// 接続情報を消すが deviceId は残す。
    func reset() {
        for key in [Key.bucketName, Key.region, Key.syncRootPath,
                    Key.pollingIntervalSeconds, Key.setupCompleted,
                    Key.uploadSizeLimitBytes,
                    Key.uploadBandwidthBytesPerSec, Key.downloadBandwidthBytesPerSec,
                    Key.notificationsEnabled] {
            defaults.removeObject(forKey: key)
        }
    }

    /// deviceId も含めて完全に消す（factoryReset 用）。
    func resetIncludingDeviceId() {
        reset()
        defaults.removeObject(forKey: Key.deviceId)
    }
}
