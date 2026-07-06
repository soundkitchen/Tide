import Foundation

/// File Provider 書込経路（M5 Phase 5-2）の純粋判定。FP の型には依存しない
/// （Data / String のみ受ける）— `TideFileProvider` ターゲットは TideTests から import
/// できないため、テスト可能なロジックは TideCore に置く。
public enum FileProviderWritePolicy {
    /// FP の `NSFileProviderItemVersion.contentVersion` の中身から 3-way ベースの sha256 を
    /// 取り出す。itemVersion の発行元は `FileProviderItem.itemVersion`（file = sha256 hex の
    /// UTF-8 / directory = "dir"）なので、その逆写像 + 防御的検証。
    /// - "dir" / 非 UTF-8 / 空 / sha256 hex（64 桁小文字）以外 → nil = 内容ベース不明。
    ///   nil の扱いは呼び出し側の意味論に委ねる（削除ガードは「根拠なしに消さない」= 拒否側、
    ///   アップロード競合判定は `decideUpload(base: nil)` = remote 有りなら競合側、へ倒れる）。
    public static func baseSha(fromContentVersion data: Data?) -> String? {
        guard let data, let s = String(data: data, encoding: .utf8) else { return nil }
        guard s.count == 64,
              s.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return s
    }
}
