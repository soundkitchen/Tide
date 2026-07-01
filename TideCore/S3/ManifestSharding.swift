import Foundation
import CryptoKit

public enum ManifestSharding {
    /// パスから所属シャード ID（2桁 hex）を計算する。SHA-1 の先頭 1 バイト。
    ///
    /// セキュリティ上の用途ではなく、**ファイルパスをハッシュ空間に均等にばらまく** ためだけに
    /// 使っている（ファイル名による偏りを防ぐため）。`Insecure.SHA1` で十分。
    public static func shardId(for relativePath: String) -> String {
        let bytes = Array(Insecure.SHA1.hash(data: Data(relativePath.utf8)))
        return String(format: "%02x", bytes[0])
    }
}
