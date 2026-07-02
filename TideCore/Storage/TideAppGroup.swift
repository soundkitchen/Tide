import Foundation

/// App Group（`group.org.izukawa.Tide`）関連の定数とパス解決（M5 Phase 2）。
/// app 本体と将来の `TideFileProvider` 拡張が DB / 設定 / Keychain を共有するための土台。
public enum TideAppGroup {
    /// App Group identifier。entitlements の `com.apple.security.application-groups` と一致させる。
    public static let identifier = "group.org.izukawa.Tide"

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
}
