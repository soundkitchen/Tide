import Foundation
import CryptoKit

enum HashCalculator {
    /// ストリーミングで SHA-256 を計算する (hex 小文字)。
    static func sha256(of url: URL, chunkSize: Int = 65_536) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { () -> Data in
                try handle.read(upToCount: chunkSize) ?? Data()
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// `O_NOFOLLOW`（最終コンポーネントの symlink を追従しない）でストリーミング SHA-256 を計算する（hex 小文字）。
    /// ローカル変更検出の SHA ゲート（scan/event）と reconcile 経路（`Downloader.currentLocalSha` /
    /// `applyRemoteDeletion`）で使い、「チェック〜hash の間に symlink へ差し替えられてリンク先を読む」窓を塞ぐ
    /// （#31 / D2）。本体はバッファせずチャンクごとに破棄するのでメモリ一定。最終コンポーネントが symlink なら
    /// `FileOpenError.isSymbolicLink` を投げる（祖先 symlink は対象外＝呼び出し側の PathValidator / スキャンの
    /// symlink skip に委ねる。`NoFollowFileReader` と同じ前提）。
    static func sha256NoFollow(of url: URL, chunkSize: Int = 65_536) throws -> String {
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        var hasher = SHA256()
        while let chunk = try reader.readChunk(chunkSize) {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 ダイジェスト（やバイト列）を hex 小文字に整形する。
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `NoFollowFileReader` からファイル全体を読み切り、`(本体データ, sha256 hex)` を返す。
    /// シングルパート経路で「1 回 open でハッシュも本体も賄う」ために使う（2 回 open を畳む）。
    static func readAllAndHash(_ reader: NoFollowFileReader, chunkSize: Int = 1 << 20) throws -> (data: Data, sha256: String) {
        var hasher = SHA256()
        var data = Data()
        while let chunk = try reader.readChunk(chunkSize) {
            hasher.update(data: chunk)
            data.append(chunk)
        }
        return (data, hex(hasher.finalize()))
    }
}
