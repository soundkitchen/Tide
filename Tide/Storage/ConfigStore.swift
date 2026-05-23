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
    }

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
                    Key.pollingIntervalSeconds, Key.setupCompleted] {
            defaults.removeObject(forKey: key)
        }
    }

    /// deviceId も含めて完全に消す（factoryReset 用）。
    func resetIncludingDeviceId() {
        reset()
        defaults.removeObject(forKey: Key.deviceId)
    }
}
