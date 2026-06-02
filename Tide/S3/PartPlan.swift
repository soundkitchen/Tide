import Foundation

/// マルチパートアップロードのパート分割計画と、シングル/マルチ分岐・サイズ上限判定をまとめた純粋ロジック。
/// DB / S3 / ファイルシステムに一切依存しないので単体テストしやすい。
enum PartPlan {
    /// S3 マルチパートの最小パートサイズ（最終パートを除く）。
    static let minPartSize: Int = 5 * 1024 * 1024            // 5 MiB
    /// パートサイズの上限。常駐メモリ（≈ partSize ×（inflight+1））を抑えるための cap（L11）。
    /// これを超えるのは、10,000 パート上限に収まらない超巨大ファイル（おおむね 640GiB 超）だけ。
    static let maxPartSize: Int = 64 * 1024 * 1024           // 64 MiB
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
    /// 目標パート数（9,000）基準で割った値を `[5MiB, maxPartSize]` にクランプし、常駐メモリを抑える（L11）。
    /// ただし 10,000 パート上限に収まらない超巨大ファイルだけは、収めるのに必要な分まで `partSize` を引き上げる
    /// （このとき maxPartSize を超える）。MiB 境界へ切り上げているため `partCount ≤ 10,000` を常に満たす。
    static func plan(forFileSize fileSize: Int64) -> Plan {
        let oneMiB: Int64 = 1024 * 1024
        func ceilToMiB(_ bytes: Int64) -> Int64 {
            let raw = max(1, bytes)
            return ((raw + oneMiB - 1) / oneMiB) * oneMiB
        }
        // 目標パート数で割った基準値を [minPartSize, maxPartSize] にクランプ。
        let targetBased = ceilToMiB(fileSize <= 0 ? 1 : (fileSize + targetMaxParts - 1) / targetMaxParts)
        var partSize = min(max(Int64(minPartSize), targetBased), Int64(maxPartSize))
        // 10,000 パートに収めるのに必要な最小 partSize（巨大ファイルでは cap を上回る）。
        let minToFit = ceilToMiB(fileSize <= 0 ? 1 : (fileSize + Int64(maxPartCount) - 1) / Int64(maxPartCount))
        partSize = max(partSize, minToFit)

        let count = Int(partCount(forFileSize: fileSize, partSize: partSize))
        return Plan(partSize: Int(partSize), partCount: count)
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
