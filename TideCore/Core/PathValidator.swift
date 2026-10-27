import Foundation

/// マニフェスト由来の path/shardId は基本的に攻撃者制御可能なので、
/// ローカル FS 操作の入口で必ず通すバリデーション群。
public enum PathValidator {

    public enum ValidationError: Error, CustomStringConvertible {
        case invalidRelativePath(String, reason: String)
        case escapesSyncRoot(String)
        case escapesSyncRootViaSymlink(String)
        case invalidShardId(String)

        public var description: String {
            switch self {
            case .invalidRelativePath(let p, let r):  return "invalid relative path \(p): \(r)"
            case .escapesSyncRoot(let p):             return "path escapes sync root: \(p)"
            case .escapesSyncRootViaSymlink(let p):   return "path escapes sync root via symlinked ancestor: \(p)"
            case .invalidShardId(let s):              return "invalid shard id: \(s)"
            }
        }
    }

    /// 同期ルートからの相対パスとして安全か検証する。
    /// - 空文字でない
    /// - 先頭が `/` でない
    /// - NUL バイトを含まない
    /// - 各コンポーネントが `.` / `..` / 空ではない
    /// - 区切りの `/` が直後の結合文字と 1 つの書記素になっていない
    ///
    /// 判定はすべて UTF-8 バイト単位で行う（#137）。Swift の `String` の操作（`split` / `hasPrefix` /
    /// `contains`）は書記素単位なので、`/` や `\` の直後に結合文字（例 U+0301）が付くと区切りや
    /// 禁止文字として見えなくなり、ファイルシステム（バイト単位）では `..` を含むパスが通ってしまう。
    public static func validateRelativePath(_ relativePath: String) throws {
        let slash = UInt8(ascii: "/")
        let bytes = relativePath.utf8
        guard !bytes.isEmpty else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "empty")
        }
        guard bytes.first != slash else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "absolute path")
        }
        guard !bytes.contains(0) else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "NUL byte")
        }
        // Windows 系区切りも弾く（POSIX 想定）
        guard !bytes.contains(UInt8(ascii: "\\")) else {
            throw ValidationError.invalidRelativePath(relativePath, reason: "backslash")
        }
        let components = bytes.split(separator: slash, omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty {
                throw ValidationError.invalidRelativePath(relativePath, reason: "empty component")
            }
            if component.elementsEqual(".".utf8) || component.elementsEqual("..".utf8) {
                throw ValidationError.invalidRelativePath(
                    relativePath, reason: "relative ref '\(String(decoding: component, as: UTF8.self))'"
                )
            }
        }
        // 書記素単位でもバイト単位と同じ数に分かれること。ずれるのは `/` が直後の結合文字と
        // 1 つの書記素になっているときだけで、そのようなパスは拒否する。下流（ManifestTree・
        // 機密網の照合・FP の item 組み立てなど）は書記素単位で `split(separator: "/")` するため、
        // 通すと検証と実際の使い方で分け方が食い違う。
        let graphemeComponentCount = relativePath.split(
            separator: "/", omittingEmptySubsequences: false
        ).count
        guard graphemeComponentCount == components.count else {
            throw ValidationError.invalidRelativePath(
                relativePath, reason: "separator combined with following character"
            )
        }
    }

    /// `relativePath` を `syncRoot` 配下に展開し、解決後の絶対パスが root の配下に収まるか検証する。
    /// validateRelativePath を通過したパスでも、念のためルート脱出をチェックする二段構え。
    public static func resolveSafely(relativePath: String, syncRoot: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let full = syncRoot.appendingPathComponent(relativePath)
        let rootPath = syncRoot.standardizedFileURL.path
        let fullPath = full.standardizedFileURL.path
        guard fullPath == rootPath || fullPath.hasPrefix(rootPath + "/") else {
            throw ValidationError.escapesSyncRoot(relativePath)
        }
        return full
    }

    /// `resolveSafely` に加えて、書込・削除経路で**祖先ディレクトリの symlink によるルート脱出**を防ぐ。
    ///
    /// `resolveSafely` は `standardizedFileURL` で字句的に root 配下を判定するだけで symlink を解決しない。
    /// syncRoot 内に外部を指す symlink ディレクトリ（例 `data/ → /Volumes/ext`）があると、マニフェスト
    /// 由来の `data/x/evil` が字句上 root 配下なので通過し、`createDirectory(withIntermediateDirectories:)`
    /// / `moveItem` / `removeItem` が symlink を辿って syncRoot 外へ到達してしまう（security F2 / M6）。
    ///
    /// そこで「解決後 URL の**最深の既存祖先ディレクトリ**の実パス（symlink 解決後）が syncRoot の実パス
    /// 配下に収まる」ことを検証する。root 側も `resolvingSymlinksInPath()` で解決して同一基準で比較する
    /// （`/tmp`→`/private/tmp` などの差異を吸収するため）。
    ///
    /// 最終コンポーネント自身が symlink のケースは呼び出し側（Downloader）の `isSymbolicLink` ガードが担当する。
    /// 本メソッドは祖先専用。
    public static func resolveForWrite(relativePath: String, syncRoot: URL) throws -> URL {
        let full = try resolveSafely(relativePath: relativePath, syncRoot: syncRoot)
        let realRoot = syncRoot.resolvingSymlinksInPath().standardizedFileURL.path

        // 最深の既存祖先ディレクトリを探す（書込時に createDirectory が辿る対象）。
        var ancestor = full.deletingLastPathComponent()
        let fm = FileManager.default
        while !fm.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }  // ファイルシステムルート到達
            ancestor = parent
        }

        let realAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        guard realAncestor == realRoot || realAncestor.hasPrefix(realRoot + "/") else {
            throw ValidationError.escapesSyncRootViaSymlink(relativePath)
        }
        return full
    }

    /// `url` がシンボリックリンクか（リンク先は辿らず、その場所のメタデータで判定）。
    /// 存在しないパスは false。書込/読込直前の symlink 再チェックに使う共有ヘルパ。
    public static func isSymbolicLink(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink ?? false
    }

    /// 2 つの URL が同一のファイルシステム実体（同一 volume + file id）を指すか。
    /// パス文字列の等値比較では、フォルダのリネーム/移動（bookmark はファイル ID で追跡し
    /// 新パスを返す）や symlink 経由の別表記を正しく扱えないため、同一性はこれで判定する。
    /// `fileResourceIdentifier` は symlink 自身の ID を返すので、先に symlink を解決して
    /// 「最終的に指しているディレクトリ」同士で比較する。
    /// どちらかが存在しない/読めない場合は false（＝同一と確認できない側に倒す）。
    public static func isSameFileSystemObject(_ a: URL, _ b: URL) -> Bool {
        guard
            let ra = try? a.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
            let rb = try? b.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return ra.isEqual(rb)
    }

    /// 実ユーザホーム（`/Users/<name>`）。App Sandbox 下では `NSHomeDirectory()` が
    /// コンテナホーム（`~/Library/Containers/<bundle id>/Data`）を返すため、
    /// 「ホーム直下か」等の実ホーム基準の判定にはこちらを使う。
    public static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// `^[0-9a-f]{2}$`（小文字 hex 2 桁）以外を弾く。
    public static func validateShardId(_ shardId: String) throws {
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
