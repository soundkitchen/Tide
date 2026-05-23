import Foundation

/// マニフェスト由来の path/shardId は基本的に攻撃者制御可能なので、
/// ローカル FS 操作の入口で必ず通すバリデーション群。
enum PathValidator {

    enum ValidationError: Error, CustomStringConvertible {
        case invalidRelativePath(String, reason: String)
        case escapesSyncRoot(String)
        case invalidShardId(String)

        var description: String {
            switch self {
            case .invalidRelativePath(let p, let r): return "invalid relative path \(p): \(r)"
            case .escapesSyncRoot(let p):            return "path escapes sync root: \(p)"
            case .invalidShardId(let s):             return "invalid shard id: \(s)"
            }
        }
    }

    /// 同期ルートからの相対パスとして安全か検証する。
    /// - 空文字でない
    /// - 先頭が `/` でない
    /// - NUL バイトを含まない
    /// - 各コンポーネントが `.` / `..` / 空ではない
    /// - ハードコード除外 (`.tide`) に該当しない
    static func validateRelativePath(_ relativePath: String) throws {
        guard !relativePath.isEmpty else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "empty")
        }
        guard !relativePath.hasPrefix("/") else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "absolute path")
        }
        guard !relativePath.contains("\u{0}") else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "NUL byte")
        }
        // Windows 系区切りも弾く（POSIX 想定）
        guard !relativePath.contains("\\") else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "backslash")
        }
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            let c = String(component)
            if c.isEmpty {
                throw ValidationError.invalidRelativePath(relativePath, reason: "empty component")
            }
            if c == "." || c == ".." {
                throw ValidationError.invalidRelativePath(relativePath, reason: "relative ref '\(c)'")
            }
        }
    }

    /// `relativePath` を `syncRoot` 配下に展開し、解決後の絶対パスが root の配下に収まるか検証する。
    /// validateRelativePath を通過したパスでも、念のためルート脱出をチェックする二段構え。
    static func resolveSafely(relativePath: String, syncRoot: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let full = syncRoot.appendingPathComponent(relativePath)
        let rootPath = syncRoot.standardizedFileURL.path
        let fullPath = full.standardizedFileURL.path
        guard fullPath == rootPath || fullPath.hasPrefix(rootPath + "/") else {
            throw ValidationError.escapesSyncRoot(relativePath)
        }
        return full
    }

    /// `^[0-9a-f]{2}$`（小文字 hex 2 桁）以外を弾く。
    static func validateShardId(_ shardId: String) throws {
        guard shardId.count == 2 else {
            throw ValidationError.invalidShardId(shardId)
        }
        for ch in shardId {
            switch ch {
            case "0"..."9", "a"..."f":
                continue
            default:
                throw ValidationError.invalidShardId(shardId)
            }
        }
    }
}
