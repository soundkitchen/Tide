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
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
