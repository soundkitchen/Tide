import Foundation

/// アプリ設定の永続化（UserDefaults ベース）。認証情報は別途 KeychainStore。
public final class ConfigStore: @unchecked Sendable {
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
        static let syncRootBookmark = "tide.syncRootBookmark"
    }

    /// 1 ファイルあたりのアップロードサイズ上限の既定値（1 GiB）。
    public static let defaultUploadSizeLimitBytes: Int64 = 1 * 1024 * 1024 * 1024

    /// `LegacyStateMigrator` が旧 standard defaults から group suite へコピーするキー一覧。
    /// deviceId を含む（マニフェスト上のデバイス識別を移行後も維持する）。
    public static let migratableKeys: [String] = [
        Key.bucketName, Key.region, Key.syncRootPath, Key.deviceId,
        Key.pollingIntervalSeconds, Key.setupCompleted,
        Key.uploadSizeLimitBytes,
        Key.uploadBandwidthBytesPerSec, Key.downloadBandwidthBytesPerSec,
        Key.notificationsEnabled
    ]

    /// セットアップ完了フラグの defaults キー（`LegacyStateMigrator` の移行要否判定用）。
    public static var setupCompletedDefaultsKey: String { Key.setupCompleted }

    /// 既定は App Group 共有 suite（M5 Phase 2 で標準 defaults から移設）。
    /// 旧 standard defaults からの一度きり移行は `LegacyStateMigrator` が行う。
    public init(defaults: UserDefaults = TideAppGroup.sharedDefaults()) {
        self.defaults = defaults
    }

    public var bucketName: String? {
        get { defaults.string(forKey: Key.bucketName) }
        set { defaults.set(newValue, forKey: Key.bucketName) }
    }

    public var region: String? {
        get { defaults.string(forKey: Key.region) }
        set { defaults.set(newValue, forKey: Key.region) }
    }

    public var syncRootPath: String? {
        get { defaults.string(forKey: Key.syncRootPath) }
        set { defaults.set(newValue, forKey: Key.syncRootPath) }
    }

    public var pollingIntervalSeconds: Int {
        get {
            let v = defaults.integer(forKey: Key.pollingIntervalSeconds)
            return v == 0 ? 180 : v
        }
        set { defaults.set(newValue, forKey: Key.pollingIntervalSeconds) }
    }

    public var setupCompleted: Bool {
        get { defaults.bool(forKey: Key.setupCompleted) }
        set { defaults.set(newValue, forKey: Key.setupCompleted) }
    }

    /// 1 ファイルあたりのアップロードサイズ上限（バイト）。
    /// `-1` = 無制限。キー未設定（`0`）のときは既定値（1 GiB）を返す（`pollingIntervalSeconds` と同じ流儀）。
    /// この上限はアップロード方向のみに適用し、ダウンロード（復元）は常に許可する。
    public var uploadSizeLimitBytes: Int64 {
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
    public var uploadBandwidthBytesPerSec: Int64 {
        get {
            guard defaults.object(forKey: Key.uploadBandwidthBytesPerSec) != nil else { return -1 }
            return Int64(defaults.integer(forKey: Key.uploadBandwidthBytesPerSec))
        }
        set { defaults.set(Int(newValue), forKey: Key.uploadBandwidthBytesPerSec) }
    }

    /// ダウンロード（復元）の帯域上限（bytes/sec）。`<= 0` = 無制限。既定は無制限（`-1`）。
    public var downloadBandwidthBytesPerSec: Int64 {
        get {
            guard defaults.object(forKey: Key.downloadBandwidthBytesPerSec) != nil else { return -1 }
            return Int64(defaults.integer(forKey: Key.downloadBandwidthBytesPerSec))
        }
        set { defaults.set(Int(newValue), forKey: Key.downloadBandwidthBytesPerSec) }
    }

    /// 競合発生・未バックアップ確定（サイズ超過 / give-up / 不安定）を OS 通知で知らせるか。
    /// キー未設定なら既定 on（オプトアウト方式）。実際に通知を出すかは OS の許可状態にも従う。
    public var notificationsEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.notificationsEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.notificationsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// 同期フォルダの security-scoped bookmark（App Sandbox 下での再アクセス手段・M5 Phase 2）。
    /// セットアップ時（パネル選択）に発行し、bootstrap が解決して scoped アクセスを開始する。
    /// デバイス固有バイナリなので `migratableKeys` / `SettingsTransfer` には含めない。
    public var syncRootBookmark: Data? {
        get { defaults.data(forKey: Key.syncRootBookmark) }
        set { defaults.set(newValue, forKey: Key.syncRootBookmark) }
    }

    /// 初回アクセス時に UUID を自動生成して保存する。以降不変。
    public var deviceId: String {
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
    /// キー一覧は `migratableKeys` から導出して二重管理を避ける（PR #49 レビュー #6）。
    /// 差分は deviceId（reset では残す）と syncRootBookmark（デバイス固有で移行対象外だが
    /// reset では消す）の 2 つだけで、それぞれ明示的に扱う。
    public func reset() {
        for key in Self.migratableKeys where key != Key.deviceId {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Key.syncRootBookmark)
    }

    /// deviceId も含めて完全に消す（factoryReset 用）。
    public func resetIncludingDeviceId() {
        reset()
        defaults.removeObject(forKey: Key.deviceId)
    }
}
