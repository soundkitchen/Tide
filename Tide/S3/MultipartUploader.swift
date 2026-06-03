import Foundation
import CryptoKit

/// `MultipartUploader` が必要とする S3 マルチパート操作の最小シーム。
/// 本番は `TideS3Client` が適合し、テストはフェイクを差し込んで（ネットワーク無しで）orchestration を検証する。
/// `withThrowingTaskGroup` の `@Sendable` クロージャへ実体を渡すため `Sendable` を要求する。
protocol MultipartUploadClient: Sendable {
    func createMultipartUpload(key: String, contentType: String, metadata: [String: String]) async throws -> String
    func uploadPart(key: String, uploadId: String, partNumber: Int, body: Data) async throws -> String
    func completeMultipartUpload(key: String, uploadId: String, parts: [(partNumber: Int, etag: String)]) async throws -> TideS3Client.PutObjectResult
    func abortMultipartUpload(key: String, uploadId: String) async throws
}

extension TideS3Client: MultipartUploadClient {}

/// 大ファイルをマルチパートでアップロードする。
///
/// 単一の `NoFollowFileReader`（O_NOFOLLOW の 1 FD）から「順番に読みつつ SHA-256 を逐次更新」し、
/// 読み終えたパートを有界並列で UploadPart する。**読む順序＝ハッシュ更新順序**を保つことで、
/// 並列アップロードしても全体ハッシュは正しく確定する。ハッシュ計算と本体読込が同一 FD なので
/// アップロード時の TOCTOU 窓（M5 / F3 / L9）も畳まれている。
struct MultipartUploader {
    let s3: any MultipartUploadClient
    /// パート単位リトライの方針（既定は本番値。テストは短い遅延を注入して高速化する）。
    var retryPolicy: RetryPolicy = .default

    /// 同時に in-flight にするパート数の上限（メモリ ≈ partSize × (maxInflight + 1)）。
    static let maxInflightParts = 3

    /// セッション内のパート単位リトライ方針（瞬断を吸収する。中断・再開の (a)）。
    struct RetryPolicy: Sendable {
        /// 1 パートあたりの最大試行回数。
        var maxAttempts: Int
        /// 指数バックオフの基準秒。遅延 ≈ `baseDelaySeconds × 2^(attempt-1) × ジッタ`。
        var baseDelaySeconds: Double
        /// バックオフの上限秒。
        var maxDelaySeconds: Double

        static let `default` = RetryPolicy(maxAttempts: 3, baseDelaySeconds: 2, maxDelaySeconds: 30)
    }

    struct Result: Sendable {
        let put: TideS3Client.PutObjectResult
        let sha256: String
    }

    /// `reader` からファイルを読み切ってマルチパートアップロードする。
    /// 恒久失敗時は best-effort で abort してから throw（呼び出し側のファイル単位リトライに委ねる）。
    func upload(
        key: String,
        reader: NoFollowFileReader,
        partSize: Int,
        contentType: String = "application/octet-stream",
        metadata: [String: String] = [:]
    ) async throws -> Result {
        let client = s3
        let policy = retryPolicy
        let uploadId = try await client.createMultipartUpload(
            key: key, contentType: contentType, metadata: metadata
        )

        do {
            var hasher = SHA256()
            var parts: [(partNumber: Int, etag: String)] = []
            var partNumber = 0

            // body 内は @Sendable でないので reader / hasher / parts を直接キャプチャしてよい。
            // addTask の子クロージャは @Sendable なので、Sendable な値（client / String / Int / Data / policy）だけを渡す。
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var inflight = 0
                while let chunk = try reader.readChunk(partSize) {
                    hasher.update(data: chunk)         // 直列更新（読む順＝正しい全体ハッシュ）
                    partNumber += 1
                    let n = partNumber
                    let body = chunk
                    if inflight >= Self.maxInflightParts {
                        let done = try await group.next()!
                        parts.append((partNumber: done.0, etag: done.1))
                        inflight -= 1
                    }
                    group.addTask {
                        let etag = try await Self.uploadPartWithRetry(
                            s3: client, key: key, uploadId: uploadId, partNumber: n, body: body, policy: policy
                        )
                        return (n, etag)
                    }
                    inflight += 1
                }
                for try await done in group {
                    parts.append((partNumber: done.0, etag: done.1))
                }
            }

            // L10: マルチパート選択（fstat で 16MiB 超）後、createMultipartUpload の往復中に対象ファイルが
            // 0 バイトへ切り詰められると、O_NOFOLLOW の FD は何も読めず parts が空になる。空のまま Complete
            // すると S3 が MalformedXML を返すので、ここで明示的に弾く（catch が abort し、上位のファイル単位
            // リトライ → 次回スキャンが縮小後サイズでシングルパート再送して自己回復する）。
            guard !parts.isEmpty else {
                throw SyncError.ioError(underlying: NSError(
                    domain: "Tide.MultipartUploader", code: -40,
                    userInfo: [NSLocalizedDescriptionKey: "no parts read (file shrank during multipart upload?)"]
                ))
            }

            let sha = HashCalculator.hex(hasher.finalize())
            let put = try await client.completeMultipartUpload(
                key: key, uploadId: uploadId, parts: parts
            )
            return Result(put: put, sha256: sha)
        } catch {
            // best-effort で中止（失敗してもライフサイクル tide-abort-incomplete-multipart が 7 日後に掃除）。
            try? await client.abortMultipartUpload(key: key, uploadId: uploadId)
            throw error
        }
    }

    private static func uploadPartWithRetry(
        s3: any MultipartUploadClient,
        key: String,
        uploadId: String,
        partNumber: Int,
        body: Data,
        policy: RetryPolicy
    ) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await s3.uploadPart(
                    key: key, uploadId: uploadId, partNumber: partNumber, body: body
                )
            } catch {
                attempt += 1
                if attempt >= policy.maxAttempts { throw error }
                // 指数バックオフ + ジッタ（上限 cap）。
                let base = policy.baseDelaySeconds * pow(2.0, Double(attempt - 1))
                let jitter = Double.random(in: 0.75...1.25)
                let delay = min(base * jitter, policy.maxDelaySeconds)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}
