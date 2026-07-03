import Foundation

/// App Group（`group.org.izukawa.Tide`）関連の定数とパス解決（M5 Phase 2）。
/// app 本体と将来の `TideFileProvider` 拡張が DB / 設定 / Keychain を共有するための土台。
public enum TideAppGroup {
    /// App Group identifier。entitlements の `com.apple.security.application-groups` と一致させる。
    ///
    /// **チーム ID プレフィックス形式**（macOS 慣習）を使う: `group.` 始まりの ID は macOS では
    /// TCC 保護され、provisioning profile での正式許可が無いと **UI を持たない拡張プロセスは
    /// 問答無用で拒否される**（containermanagerd: "Group containers identifiers should be
    /// prefixed by requestor's team ID"。Phase 3 実機で File Provider 拡張が group defaults を
    /// 読めず notAuthenticated になった実害）。チーム ID プレフィックスなら署名のチーム一致だけで
    /// アクセスでき、Portal / プロファイル依存ゼロ。
    public static let identifier = "G5G54TCH8W.org.izukawa.Tide"

    /// 旧 App Group identifier（M5 Phase 2 で一時使用した `group.` 形式）。
    /// `LegacyStateMigrator` の移行元としてのみ参照する。アプリ側 entitlement には
    /// 移行期間中これも残す（旧コンテナを読むため）。
    public static let legacyIdentifier = "group.org.izukawa.Tide"

    /// Keychain access group。entitlements の `keychain-access-groups` の先頭
    /// （`$(AppIdentifierPrefix)org.izukawa.Tide`）と同値。既存アイテムは元から
    /// このグループに保存されている（entitlements に 1 つしか無いグループが既定の
    /// 保存先になる）ため、明示指定への切替に Keychain アイテムの移行は不要。
    public static let keychainAccessGroup = "G5G54TCH8W.org.izukawa.Tide"

    /// group container のルート URL。
    /// entitlement 欠落・署名不正のときのみ nil になり得るので、その場合は throw。
    public static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw SyncError.notConfigured(reason: "App Group container unavailable: \(identifier)")
        }
        return url
    }

    /// group container 内の `Library/Application Support/Tide`（ローカル DB の置き場所）。
    public static func supportDirectoryURL() throws -> URL {
        try containerURL().appendingPathComponent(
            "Library/Application Support/Tide", isDirectory: true
        )
    }

    /// group 共有の UserDefaults suite。suiteName は固定の有効値なので nil にならない。
    public static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: identifier)!
    }

    /// 旧 group container のルート（移行元）。entitlement が無い環境では nil。
    public static func legacyContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: legacyIdentifier)
    }
}
