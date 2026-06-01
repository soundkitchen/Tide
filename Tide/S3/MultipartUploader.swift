import Foundation
import CryptoKit

/// 大ファイルをマルチパートでアップロードする。
///
/// 単一の `NoFollowFileReader`（O_NOFOLLOW の 1 FD）から「順番に読みつつ SHA-256 を逐次更新」し、
/// 読み終えたパートを有界並列で UploadPart する。**読む順序＝ハッシュ更新順序**を保つことで、
/// 並列アップロードしても全体ハッシュは正しく確定する。ハッシュ計算と本体読込が同一 FD なので
/// アップロード時の TOCTOU 窓（M5 / F3 / L9）も畳まれている。
struct MultipartUploader {
    let s3: TideS3Client

    /// セッション内のパート単位リトライ回数（瞬断を吸収する。中断・再開の (a)）。
    static let maxPartAttempts = 3
    /// 同時に in-flight にするパート数の上限（メモリ ≈ partSize × (maxInflight + 1)）。
    static let maxInflightParts = 3

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
        let uploadId = try await client.createMultipartUpload(
            key: key, contentType: contentType, metadata: metadata
        )

        do {
            var hasher = SHA256()
            var parts: [(partNumber: Int, etag: String)] = []
            var partNumber = 0

            // body 内は @Sendable でないので reader / hasher / parts を直接キャプチャしてよい。
            // addTask の子クロージャは @Sendable なので、Sendable な値（client / String / Int / Data）だけを渡す。
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
                            s3: client, key: key, uploadId: uploadId, partNumber: n, body: body
                        )
                        return (n, etag)
                    }
                    inflight += 1
                }
                for try await done in group {
                    parts.append((partNumber: done.0, etag: done.1))
                }
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
        s3: TideS3Client,
        key: String,
        uploadId: String,
        partNumber: Int,
        body: Data
    ) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await s3.uploadPart(
                    key: key, uploadId: uploadId, partNumber: partNumber, body: body
                )
            } catch {
                attempt += 1
                if attempt >= maxPartAttempts { throw error }
                // 指数バックオフ + ジッタ（30 秒 cap）。
                let base = pow(2.0, Double(attempt))
                let jitter = Double.random(in: 0.75...1.25)
                let delay = min(base * jitter, 30)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}
