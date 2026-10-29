import Foundation

/// M1 のハードコード除外。`.syncignore` 対応は M3。
///
/// 「OS のジャンク」だけでなく、**「うっかり同期したら困る秘匿ファイル」** も既定で除外する
/// （`.env`, `id_rsa`, `*.pem`, `.aws/` 等）。ユーザがホームディレクトリを同期ルートにしてしまった
/// 場合でも、これらは S3 へ流出しない最低限の安全網。
public enum HardcodedIgnoreRules {
    public static let exactNames: Set<String> = [
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

    public static let prefixPatterns: [String] = [
        ".DocumentRevisions-V100",
        ".PKInstallSandboxManager",
        "._",              // AppleDouble files
        ".env."            // .env.local / .env.production 等
    ]

    // `.key` は入れない（#140）: Keynote の書類（単一ファイル = zip / パッケージ = フォルダ）と同じ拡張子で、
    // 入れると Keynote がすべて黙ってバックアップから外れる（機密網は `.syncignore` の `!` でも覆せない）。
    // 秘密鍵の `.key` は各自 `.syncignore` で除外する（既定 `.syncignore` のコメント例と `docs/04` で案内）。
    public static let suffixPatterns: [String] = [
        ".pem",
        ".p12",
        ".pfx",
        ".keystore"
    ]

    // 照合用の小文字版（#136）。上の公開リストは設定画面の表示用に元の表記のまま残す。
    // パターンはすべて ASCII なので `lowercased()` で APFS（既定で大文字小文字を区別しない）と同じ一致になる。
    private static let lowercasedExactNames = Set(exactNames.map { $0.lowercased() })
    private static let lowercasedPrefixPatterns = prefixPatterns.map { $0.lowercased() }
    private static let lowercasedSuffixPatterns = suffixPatterns.map { $0.lowercased() }

    /// path: 同期ルートからの相対パス（POSIX 区切り）
    ///
    /// 大文字小文字を区別せずに照合する（#136）。APFS では `Server.PEM` も `.ENV` も普通に
    /// 作れるため、区別すると機密網を素通りして S3 へ上がる。
    public static func shouldIgnore(relativePath: String) -> Bool {
        // ホットパス（スキャン / FileWatcher / FP createItem）なので小文字化はパス全体で 1 回だけ。
        for c in relativePath.lowercased().split(separator: "/") {
            if lowercasedExactNames.contains(String(c)) { return true }
            for prefix in lowercasedPrefixPatterns where c.hasPrefix(prefix) {
                return true
            }
            for suffix in lowercasedSuffixPatterns where c.hasSuffix(suffix) {
                return true
            }
        }
        return false
    }
}
