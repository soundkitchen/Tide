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

    /// 中断・再開（サブ D）の文脈。これを渡すと checkpoint を `transfer_state` へ永続化し、
    /// プロセス再起動を跨いだファイル内再開を行う。nil なら従来挙動（永続化・再開なし）。
    struct ResumeContext: Sendable {
        /// `transfer_state` のキー（同期ルートからの相対パス）。
        let path: String
        /// 再開時にローカルファイルが変わっていないか照合するスナップショット。
        let fileMtime: Double
        let fileSize: Int64
        let store: any UploadCheckpointStore
    }

    /// `reader` からファイルを読み切ってマルチパートアップロードする。
    ///
    /// `resume` を渡すと:
    /// - 既存 checkpoint があり mtime/size が一致すれば、その UploadId と完了パートを引き継いで
    ///   **未送パートだけ送る**（既送パートも読み順に hash 更新して全体 SHA を復元する）。
    /// - mtime/size が変わっていれば古い MPU を best-effort abort してフル再開する。
    /// - 失敗（throw）時は **abort も checkpoint クリアもしない**＝MPU と進捗を保持し、次回の
    ///   ファイル単位リトライ／次回起動で再開できるようにする（恒久失敗の残骸は
    ///   ライフサイクル tide-abort-incomplete-multipart と起動時掃除に委ねる）。
    ///
    /// `resume` が nil のときは従来挙動: 失敗時に best-effort abort してから throw する。
    func upload(
        key: String,
        reader: NoFollowFileReader,
        partSize requestedPartSize: Int,
        contentType: String = "application/octet-stream",
        metadata: [String: String] = [:],
        resume: ResumeContext? = nil,
        expectedStat: NoFollowFileReader.FileInfo? = nil,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Result {
        let client = s3
        let policy = retryPolicy

        // 再開判定。mtime/size 一致なら既存 UploadId・完了パート・partSize を引き継ぐ。
        var partSize = requestedPartSize
        var completedByNumber: [Int: String] = [:]
        let uploadId: String

        if let resume {
            let existing = try await resume.store.loadUpload(path: resume.path)
            if let existing,
               existing.fileMtime == resume.fileMtime,
               existing.fileSize == resume.fileSize {
                uploadId = existing.uploadId
                partSize = existing.partSize     // 永続値を使う（オフセット境界を揃える）
                for p in existing.completedParts { completedByNumber[p.n] = p.etag }
            } else {
                // 行が無い or ファイルが変わった → 古い MPU を掃除してフル再開。
                if let existing {
                    try? await client.abortMultipartUpload(key: key, uploadId: existing.uploadId)
                }
                uploadId = try await client.createMultipartUpload(
                    key: key, contentType: contentType, metadata: metadata
                )
                try await resume.store.beginUpload(
                    path: resume.path, uploadId: uploadId,
                    partSize: partSize, fileMtime: resume.fileMtime, fileSize: resume.fileSize
                )
            }
        } else {
            uploadId = try await client.createMultipartUpload(
                key: key, contentType: contentType, metadata: metadata
            )
        }

        do {
            var hasher = SHA256()
            var parts: [(partNumber: Int, etag: String)] = []
            var partNumber = 0
            // 進捗報告（パート完了ごと）。既送パートは即時、未送パートは UploadPart 完了時に加算する。
            var uploadedBytes: Int64 = 0
            var partBytes: [Int: Int] = [:]

            // body 内は @Sendable でないので reader / hasher / parts / resume を直接キャプチャしてよい。
            // addTask の子クロージャは @Sendable なので、Sendable な値（client / String / Int / Data / policy）だけを渡す。
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var inflight = 0
                while let chunk = try reader.readChunk(partSize) {
                    hasher.update(data: chunk)         // 既送/未送に関わらず読み順に更新（全体ハッシュを復元）
                    partNumber += 1
                    let n = partNumber

                    // 既に完了済み（前回セッション）→ アップロードせず parts にだけ反映。即進捗加算。
                    if let etag = completedByNumber[n] {
                        parts.append((partNumber: n, etag: etag))
                        uploadedBytes += Int64(chunk.count)
                        onProgress?(uploadedBytes)
                        continue
                    }

                    let body = chunk
                    partBytes[n] = chunk.count
                    if inflight >= Self.maxInflightParts {
                        let done = try await group.next()!
                        parts.append((partNumber: done.0, etag: done.1))
                        uploadedBytes += Int64(partBytes[done.0] ?? 0)
                        onProgress?(uploadedBytes)
                        if let resume {
                            try await resume.store.recordCompletedPart(
                                path: resume.path, part: CompletedPart(n: done.0, etag: done.1)
                            )
                        }
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
                    uploadedBytes += Int64(partBytes[done.0] ?? 0)
                    onProgress?(uploadedBytes)
                    if let resume {
                        try await resume.store.recordCompletedPart(
                            path: resume.path, part: CompletedPart(n: done.0, etag: done.1)
                        )
                    }
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

            // L6 (A-detect): completeMultipartUpload の前に再 stat し、読込中にローカルが変化していたら
            // torn なので complete しない（現行 S3 オブジェクトは未差し替えのまま保全される）。下の catch が
            // abort + (resume) checkpoint クリアして、新 mtime でのフル再開に委ねる。
            if let expectedStat {
                let finalStat = try reader.info()
                if !StabilityCheck.isStable(expected: expectedStat, final: finalStat) {
                    throw SyncError.fileChangedDuringUpload(path: resume?.path ?? key)
                }
            }

            let sha = HashCalculator.hex(hasher.finalize())
            let put = try await client.completeMultipartUpload(
                key: key, uploadId: uploadId, parts: parts
            )
            if let resume {
                try await resume.store.clearUpload(path: resume.path)
            }
            return Result(put: put, sha256: sha)
        } catch {
            // 不安定（読込中に内容が変化＝L6 A-detect）は、この MPU が stale なので resume 有無に関わらず
            // abort + checkpoint クリアして、新 mtime でのフル再開に委ねる（保持して再開すると stale な
            // 旧パートを使い続けてしまう）。
            let fileChanged: Bool
            if case SyncError.fileChangedDuringUpload = error { fileChanged = true } else { fileChanged = false }

            if resume == nil || fileChanged {
                // resume なしの従来挙動 or 不安定: best-effort で中止
                // （残骸はライフサイクル tide-abort-incomplete-multipart が掃除）。
                try? await client.abortMultipartUpload(key: key, uploadId: uploadId)
            }
            if fileChanged, let resume {
                try? await resume.store.clearUpload(path: resume.path)
            }
            // resume あり & 不安定でない（瞬断等）: MPU と checkpoint を保持して次回再開に委ねる（abort/clear しない）。
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
