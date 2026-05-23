import Foundation

/// M1 のハードコード除外。`.syncignore` 対応は M3。
///
/// 「OS のジャンク」だけでなく、**「うっかり同期したら困る秘匿ファイル」** も既定で除外する
/// （`.env`, `id_rsa`, `*.pem`, `.aws/` 等）。ユーザがホームディレクトリを同期ルートにしてしまった
/// 場合でも、これらは S3 へ流出しない最低限の安全網。
enum HardcodedIgnoreRules {
    static let exactNames: Set<String> = [
        // OS junk
        ".DS_Store",
        "Thumbs.db",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".AppleDouble",
        ".LSOverride",
        ".VolumeIcon.icns",
        ".com.apple.timemachine.donotpresent",

        // Tide 自身の作業ディレクトリ（ダウンロード時の一時ファイル置き場など）
        ".tide",

        // Sensitive defaults: dotfiles
        ".env",
        ".envrc",
        ".netrc",
        ".npmrc",
        ".pgpass",
        ".aws",            // ディレクトリごと除外
        ".ssh",            // ディレクトリごと除外
        ".gnupg",          // ディレクトリごと除外
        ".kube",           // kubeconfig など
        ".docker",
        ".config",         // 雑だが secrets が紛れがち
        ".gitconfig",      // 個人情報が入ることが多い

        // Sensitive defaults: well-known key names
        "id_rsa",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "credentials"      // generic credentials file
    ]

    static let prefixPatterns: [String] = [
        ".DocumentRevisions-V100",
        ".PKInstallSandboxManager",
        "._",              // AppleDouble files
        ".env."            // .env.local / .env.production 等
    ]

    static let suffixPatterns: [String] = [
        ".pem",
        ".key",
        ".p12",
        ".pfx",
        ".keystore"
    ]

    /// path: 同期ルートからの相対パス（POSIX 区切り）
    static func shouldIgnore(relativePath: String) -> Bool {
        for component in relativePath.split(separator: "/") {
            let c = String(component)
            if exactNames.contains(c) { return true }
            for prefix in prefixPatterns where c.hasPrefix(prefix) {
                return true
            }
            for suffix in suffixPatterns where c.hasSuffix(suffix) {
                return true
            }
        }
        return false
    }
}
