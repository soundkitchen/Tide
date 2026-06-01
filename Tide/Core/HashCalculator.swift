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
