import Foundation
import Security

/// AWS 認証情報を Keychain (generic password) に保存する。
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "org.izukawa.Tide") {
        self.service = service
    }

    private enum Account {
        static let accessKeyId = "aws_access_key_id"
        static let secretAccessKey = "aws_secret_access_key"
    }

    public func save(_ credentials: AWSCredentials) throws {
        try setItem(account: Account.accessKeyId, value: credentials.accessKeyId)
        try setItem(account: Account.secretAccessKey, value: credentials.secretAccessKey)
    }

    public func load() throws -> AWSCredentials? {
        guard let key = try getItem(account: Account.accessKeyId),
              let secret = try getItem(account: Account.secretAccessKey) else {
            return nil
        }
        return AWSCredentials(accessKeyId: key, secretAccessKey: secret)
    }

    public func delete() throws {
        try deleteItem(account: Account.accessKeyId)
        try deleteItem(account: Account.secretAccessKey)
    }

    // MARK: - low-level

    /// Query / attributes に共通して付ける属性。
    /// - `kSecUseDataProtectionKeychain`: iOS 互換の Data Protection Keychain を使う（ファイルベース legacy より厳格な ACL）
    /// - `kSecAttrAccessible`: AfterFirstUnlock（メニューバー常駐前提）
    /// - `kSecAttrSynchronizable`: false（iCloud Keychain 同期を防ぐ）
    private func baseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func setItem(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: "Tide — \(account)"
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            for (k, v) in attrs { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SyncError.keychain(status: addStatus) }
        default:
            throw SyncError.keychain(status: updateStatus)
        }
    }

    private func getItem(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw SyncError.keychain(status: status)
        }
    }

    private func deleteItem(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SyncError.keychain(status: status)
        }
    }
}
