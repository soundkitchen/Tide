import Foundation

/// マルチパートアップロードのパート分割計画と、シングル/マルチ分岐・サイズ上限判定をまとめた純粋ロジック。
/// DB / S3 / ファイルシステムに一切依存しないので単体テストしやすい。
enum PartPlan {
    /// S3 マルチパートの最小パートサイズ（最終パートを除く）。
    static let minPartSize: Int = 5 * 1024 * 1024            // 5 MiB
    /// S3 マルチパートの最大パート数。
    static let maxPartCount: Int = 10_000
    /// これを超えたらマルチパート、以下ならシングル PutObject。
    static let multipartThreshold: Int64 = 16 * 1024 * 1024  // 16 MiB
    /// アダプティブ計算で目標とするパート数（10,000 の上限に対して余裕を持たせる）。
    static let targetMaxParts: Int64 = 9_000

    /// 指定サイズをマルチパートで送るか（シングル PutObject との分岐）。
    static func shouldUseMultipart(fileSize: Int64) -> Bool {
        fileSize > multipartThreshold
    }

    struct Plan: Equatable {
        let partSize: Int
        let partCount: Int
    }

    /// ファイルサイズからアダプティブにパートサイズ / パート数を決める。
    /// `partSize = max(5MiB, ceil(fileSize / 9000))` を MiB 境界に切り上げ、`partCount ≤ 10,000` を保証。
    static func plan(forFileSize fileSize: Int64) -> Plan {
        let oneMiB: Int64 = 1024 * 1024
        // ceil(fileSize / targetMaxParts)
        let rawPerPart = fileSize <= 0 ? 1 : (fileSize + targetMaxParts - 1) / targetMaxParts
        // MiB 境界に切り上げ
        let roundedToMiB = ((rawPerPart + oneMiB - 1) / oneMiB) * oneMiB
        var partSize64 = max(Int64(minPartSize), roundedToMiB)

        // 念のための防御: 万一 partCount が上限を超えるなら partSize を増やす（通常は targetMaxParts により発生しない）。
        while partCount(forFileSize: fileSize, partSize: partSize64) > Int64(maxPartCount) {
            partSize64 += oneMiB
        }

        let count = Int(partCount(forFileSize: fileSize, partSize: partSize64))
        return Plan(partSize: Int(partSize64), partCount: count)
    }

    private static func partCount(forFileSize fileSize: Int64, partSize: Int64) -> Int64 {
        guard partSize > 0 else { return 1 }
        return max(1, (fileSize + partSize - 1) / partSize)
    }

    /// アップロードサイズ上限の判定。`limitBytes ≤ 0` は無制限（-1 = 無制限センチネル / 0 = 未設定）。
    static func isWithinUploadLimit(size: Int64, limitBytes: Int64) -> Bool {
        limitBytes <= 0 || size <= limitBytes
    }
}
