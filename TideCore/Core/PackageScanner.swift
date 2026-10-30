import Foundation

/// ローカルのパッケージ（FP の createItem / modifyItem に渡るフォルダ）の中身を走査する（#140）。
///
/// - **シンボリックリンクは追従しない**: 中身に 1 つでもあればパッケージごと除外する（ユーザ確定
///   2026-10-30）。リンクだけ落として上げると、復元したパッケージが壊れて開けない。FIFO・ソケット・
///   デバイスなど通常のファイルでないもの、同期できない名前（`PathValidator`）も同じく丸ごと除外。
/// - 中身が上限（既定 10,000 件）を超えるパッケージも丸ごと除外する（`.app` を丸ごと置いた等。
///   マニフェストの書込とバッジの集計を 1 件の書類のために膨らませない）。
/// - 機密網（`HardcodedIgnoreRules`・OS のジャンクを含む）に当たる中身は**黙って飛ばす**
///   （機密網は何にも優先する・フォルダなら配下ごと）。ユーザ `.syncignore` のパターンは中身には
///   当てない — パッケージは 1 つの書類で、中身を一部だけ外すと復元しても開けない。
/// - 走査は自前の再帰下降（スタック）で、相対パスも自分で組み立てる（`walkSyncTree` と同じ方式・
///   列挙子の `skipDescendants` は使わない）。中のパッケージ（`.app` の中の `.framework` 等）にも降りる。
public enum PackageScanner {
    public static let memberLimit = 10_000

    public struct Member: Equatable, Sendable {
        /// パッケージからの相対 POSIX パス。
        public let relativePath: String
        public let url: URL
        public let size: Int64
        public let modified: Date?
    }

    public enum Exclusion: Equatable, Sendable {
        case symbolicLink(relativePath: String)
        /// 通常のファイルでもフォルダでもない（FIFO・ソケット・デバイス等）。
        case unsupportedItem(relativePath: String)
        case unsyncableName(relativePath: String)
        case tooManyFiles(limit: Int)
    }

    public enum Result: Equatable, Sendable {
        /// 上げる中身（相対パス昇順）。空のこともある（中身が無い・全部機密網に当たった）。
        case members([Member])
        case excluded(Exclusion)
    }

    public enum ScanError: Error, Equatable {
        /// 渡された URL がフォルダでない（symlink を含む）。
        case notADirectory
    }

    private static let keys: [URLResourceKey] = [
        .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// - Parameters:
    ///   - root: パッケージのフォルダ。
    ///   - packagePath: 同期ルートからのパッケージの相対パス（中身の名前の検証に使う）。
    public static func scan(root: URL, packagePath: String, limit: Int = memberLimit) throws -> Result {
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw ScanError.notADirectory
        }
        var members: [Member] = []
        var stack: [(url: URL, relative: String)] = [(root, "")]
        while let (dirURL, dirRelative) = stack.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: keys, options: [])
            for child in children {
                let name = child.lastPathComponent
                let relative = dirRelative.isEmpty ? name : dirRelative + "/" + name
                if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }
                let values = try child.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    return .excluded(.symbolicLink(relativePath: relative))
                }
                guard (try? PathValidator.validateRelativePath(packagePath + "/" + relative)) != nil else {
                    return .excluded(.unsyncableName(relativePath: relative))
                }
                if values.isDirectory == true {
                    stack.append((child, relative))
                } else if values.isRegularFile == true {
                    members.append(Member(
                        relativePath: relative, url: child,
                        size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
                    if members.count > limit { return .excluded(.tooManyFiles(limit: limit)) }
                } else {
                    return .excluded(.unsupportedItem(relativePath: relative))
                }
            }
        }
        return .members(members.sorted { $0.relativePath < $1.relativePath })
    }
}
