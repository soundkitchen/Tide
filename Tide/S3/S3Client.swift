import Foundation
import CryptoKit
@preconcurrency import AWSS3
@preconcurrency import AWSSDKIdentity
@preconcurrency import Smithy
@preconcurrency import SmithyHTTPAPI

/// AWS SDK for Swift の S3Client をラップした薄い層。
final class TideS3Client: @unchecked Sendable {
    let bucket: String
    let region: String
    let deviceId: String
    private let client: AWSS3.S3Client

    init(credentials: AWSCredentials, region: String, bucket: String, deviceId: String) throws {
        self.bucket = bucket
        self.region = region
        self.deviceId = deviceId

        let identity = AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey
        )
        let resolver = try StaticAWSCredentialIdentityResolver(identity)

        let config = try AWSS3.S3Client.S3ClientConfiguration(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        self.client = AWSS3.S3Client(config: config)
    }

    // MARK: - Bucket

    /// HeadBucket をそのまま実行する（エラーを wrap しない）。呼び出し側で
    /// S3ErrorClassifier.isNotFound / isForbidden で判別する。
    func headBucket() async throws {
        let input = HeadBucketInput(bucket: bucket)
        _ = try await client.headBucket(input: input)
    }

    func checkBucketAccess() async throws {
        do {
            try await headBucket()
        } catch {
            throw SyncError.bucketNotAccessible(reason: String(describing: error))
        }
    }

    /// 新規バケットを作成する。us-east-1 では locationConstraint を付けない。
    func createBucket() async throws {
        var config: S3ClientTypes.CreateBucketConfiguration?
        if region != "us-east-1" {
            config = S3ClientTypes.CreateBucketConfiguration(
                locationConstraint: S3ClientTypes.BucketLocationConstraint(rawValue: region)
            )
        }
        let input = CreateBucketInput(
            bucket: bucket,
            createBucketConfiguration: config
        )
        _ = try await client.createBucket(input: input)
    }

    func isVersioningEnabled() async throws -> Bool {
        let input = GetBucketVersioningInput(bucket: bucket)
        let output = try await client.getBucketVersioning(input: input)
        return output.status == .enabled
    }

    func enableVersioning() async throws {
        let input = PutBucketVersioningInput(
            bucket: bucket,
            versioningConfiguration: S3ClientTypes.VersioningConfiguration(status: .enabled)
        )
        _ = try await client.putBucketVersioning(input: input)
    }

    /// Block Public Access を 4 つの設定全部 true で投入。
    /// 既に同じ設定でも冪等（PUT セマンティクス）。
    func enforcePublicAccessBlock() async throws {
        let input = PutPublicAccessBlockInput(
            bucket: bucket,
            publicAccessBlockConfiguration: S3ClientTypes.PublicAccessBlockConfiguration(
                blockPublicAcls: true,
                blockPublicPolicy: true,
                ignorePublicAcls: true,
                restrictPublicBuckets: true
            )
        )
        _ = try await client.putPublicAccessBlock(input: input)
    }

    enum LifecycleStatus: Sendable {
        case alreadyConfigured
        case updated
    }

    /// Tide が必要とする 3 ルール（abort multipart / expire old versions / expire delete markers）が
    /// 既に揃っていればそのまま返す。揃っていなければ「ユーザ独自ルール + Tide 3 ルール」をマージして PUT する。
    ///
    /// `tide-...` の ID を持つ既存ルールは Tide のものとみなし、内容を最新の定義に差し替える。
    /// それ以外のユーザ独自ルールはすべて温存する。
    @discardableResult
    func ensureLifecycleRules() async throws -> LifecycleStatus {
        let tideRules = Self.tideLifecycleRules
        let tideIds = Set(tideRules.compactMap { $0.id })

        // 1) 現状取得（未設定なら空扱い）
        let existing: [S3ClientTypes.LifecycleRule]
        do {
            let output = try await client.getBucketLifecycleConfiguration(
                input: GetBucketLifecycleConfigurationInput(bucket: bucket)
            )
            existing = output.rules ?? []
        } catch {
            if String(describing: error).contains("NoSuchLifecycleConfiguration")
                || S3ErrorClassifier.isNotFound(error) {
                existing = []
            } else {
                throw error
            }
        }

        // 2) Tide 3 ID が全部揃っているなら現状を尊重して何もしない
        let existingIds = Set(existing.compactMap { $0.id })
        if tideIds.isSubset(of: existingIds) {
            return .alreadyConfigured
        }

        // 3) tide-* ID 持ちは外し、それ以外（ユーザ独自）は温存して結合
        let nonTide = existing.filter { rule in
            guard let id = rule.id else { return true }
            return !tideIds.contains(id)
        }
        let merged = nonTide + tideRules

        let input = PutBucketLifecycleConfigurationInput(
            bucket: bucket,
            lifecycleConfiguration: S3ClientTypes.BucketLifecycleConfiguration(rules: merged)
        )
        _ = try await client.putBucketLifecycleConfiguration(input: input)
        return .updated
    }

    private static let tideLifecycleRules: [S3ClientTypes.LifecycleRule] = [
        S3ClientTypes.LifecycleRule(
            abortIncompleteMultipartUpload: S3ClientTypes.AbortIncompleteMultipartUpload(
                daysAfterInitiation: 7
            ),
            filter: S3ClientTypes.LifecycleRuleFilter(prefix: ""),
            id: "tide-abort-incomplete-multipart",
            status: .enabled
        ),
        S3ClientTypes.LifecycleRule(
            filter: S3ClientTypes.LifecycleRuleFilter(prefix: ""),
            id: "tide-expire-old-versions",
            noncurrentVersionExpiration: S3ClientTypes.NoncurrentVersionExpiration(
                noncurrentDays: 90
            ),
            status: .enabled
        ),
        S3ClientTypes.LifecycleRule(
            expiration: S3ClientTypes.LifecycleExpiration(expiredObjectDeleteMarker: true),
            filter: S3ClientTypes.LifecycleRuleFilter(prefix: ""),
            id: "tide-expire-delete-markers",
            status: .enabled
        )
    ]

    // MARK: - Objects

    struct PutObjectResult: Sendable {
        let etag: String
        let versionId: String?
    }

    /// S3 が返す ETag は両端がダブルクォートで囲まれているので外す（全 API 共通の整形）。
    private static func cleanETag(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    func putObject(
        key: String,
        data: Data,
        contentType: String = "application/octet-stream",
        metadata: [String: String] = [:],
        ifMatch: String? = nil,
        ifNoneMatch: String? = nil
    ) async throws -> PutObjectResult {
        let input = PutObjectInput(
            body: .data(data),
            bucket: bucket,
            contentType: contentType,
            ifMatch: ifMatch,
            ifNoneMatch: ifNoneMatch,
            key: key,
            metadata: metadata,
            serverSideEncryption: .aes256  // SSE-S3 を明示
        )
        let output = try await client.putObject(input: input)
        let etag = Self.cleanETag(output.eTag)
        return PutObjectResult(etag: etag, versionId: output.versionId)
    }

    func deleteObject(key: String) async throws {
        let input = DeleteObjectInput(bucket: bucket, key: key)
        _ = try await client.deleteObject(input: input)
    }

    struct ObjectHead: Sendable {
        let etag: String
        let versionId: String?
        let size: Int64?
        let metadata: [String: String]
    }

    /// オブジェクトのメタデータのみ取得する。404 → nil。
    func headObject(key: String) async throws -> ObjectHead? {
        let input = HeadObjectInput(bucket: bucket, key: key)
        do {
            let output = try await client.headObject(input: input)
            let etag = Self.cleanETag(output.eTag)
            return ObjectHead(
                etag: etag,
                versionId: output.versionId,
                size: output.contentLength.map(Int64.init),
                metadata: output.metadata ?? [:]
            )
        } catch {
            if S3ErrorClassifier.isNotFound(error) { return nil }
            throw error
        }
    }

    struct ObjectFetch: Sendable {
        let data: Data
        let etag: String
    }

    /// オブジェクトを取得する。`maxBytes` を指定するとレスポンスサイズの自己防衛が効く
    /// （膨大な `.tide/index.json` などで OOM を起こさせない）。
    func getObject(key: String, maxBytes: Int64 = 200 * 1024 * 1024) async throws -> ObjectFetch? {
        let input = GetObjectInput(bucket: bucket, key: key)
        do {
            let output = try await client.getObject(input: input)
            // 事前にサーバ申告のサイズで弾く
            if let len = output.contentLength, Int64(len) > maxBytes {
                throw SyncError.ioError(underlying: NSError(
                    domain: "Tide.S3",
                    code: -20,
                    userInfo: [NSLocalizedDescriptionKey: "object too large: \(len) > \(maxBytes) bytes for key \(key)"]
                ))
            }
            let etag = Self.cleanETag(output.eTag)
            let data: Data
            if let body = output.body {
                data = try await body.readData() ?? Data()
            } else {
                data = Data()
            }
            // ストリーミング後にも保険でチェック（contentLength が嘘の場合）
            if Int64(data.count) > maxBytes {
                throw SyncError.ioError(underlying: NSError(
                    domain: "Tide.S3",
                    code: -21,
                    userInfo: [NSLocalizedDescriptionKey: "downloaded body exceeds maxBytes: \(data.count) > \(maxBytes)"]
                ))
            }
            return ObjectFetch(data: data, etag: etag)
        } catch let error as NoSuchKey {
            _ = error
            return nil
        } catch {
            // 404 系の他の表現にも対応（判定は S3ErrorClassifier.isNotFound に集約）
            if S3ErrorClassifier.isNotFound(error) { return nil }
            throw error
        }
    }

    // MARK: - Multipart upload

    /// マルチパートアップロードを開始し uploadId を返す。SSE-S3 を必ず付与する。
    func createMultipartUpload(
        key: String,
        contentType: String = "application/octet-stream",
        metadata: [String: String] = [:]
    ) async throws -> String {
        let input = CreateMultipartUploadInput(
            bucket: bucket,
            contentType: contentType,
            key: key,
            metadata: metadata,
            serverSideEncryption: .aes256  // SSE-S3 を明示（putObject と揃える）
        )
        let output = try await client.createMultipartUpload(input: input)
        guard let uploadId = output.uploadId else {
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.S3", code: -30,
                userInfo: [NSLocalizedDescriptionKey: "createMultipartUpload returned no uploadId"]
            ))
        }
        return uploadId
    }

    /// 1 パートをアップロードし、その eTag（クォート除去済み）を返す。
    func uploadPart(
        key: String,
        uploadId: String,
        partNumber: Int,
        body: Data
    ) async throws -> String {
        let input = UploadPartInput(
            body: .data(body),
            bucket: bucket,
            key: key,
            partNumber: partNumber,
            uploadId: uploadId
        )
        let output = try await client.uploadPart(input: input)
        let etag = Self.cleanETag(output.eTag)
        if etag.isEmpty {
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.S3", code: -31,
                userInfo: [NSLocalizedDescriptionKey: "uploadPart returned no eTag for part \(partNumber)"]
            ))
        }
        return etag
    }

    /// 全パートを束ねてマルチパートアップロードを完了する。返る etag は `<md5>-<partcount>` 形式。
    func completeMultipartUpload(
        key: String,
        uploadId: String,
        parts: [(partNumber: Int, etag: String)]
    ) async throws -> PutObjectResult {
        // L10: パートが 1 つも無い状態で Complete すると S3 が MalformedXML を返す。
        // 呼び出し側のバグや「アップロード中の切り詰め」を明示エラーで弾く（上位が abort する）。
        guard !parts.isEmpty else {
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.S3", code: -32,
                userInfo: [NSLocalizedDescriptionKey: "completeMultipartUpload called with no parts"]
            ))
        }
        let completed = parts
            .sorted { $0.partNumber < $1.partNumber }
            .map { S3ClientTypes.CompletedPart(eTag: $0.etag, partNumber: $0.partNumber) }
        let input = CompleteMultipartUploadInput(
            bucket: bucket,
            key: key,
            multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completed),
            uploadId: uploadId
        )
        let output = try await client.completeMultipartUpload(input: input)
        let etag = Self.cleanETag(output.eTag)
        return PutObjectResult(etag: etag, versionId: output.versionId)
    }

    /// 失敗したマルチパートアップロードを中止する（best-effort）。
    /// 呼び忘れ・失敗時もライフサイクルルール tide-abort-incomplete-multipart が 7 日後に掃除する。
    func abortMultipartUpload(key: String, uploadId: String) async throws {
        let input = AbortMultipartUploadInput(bucket: bucket, key: key, uploadId: uploadId)
        _ = try await client.abortMultipartUpload(input: input)
    }

    // MARK: - Streaming download

    struct DownloadResult: Sendable {
        let sha256: String
        let bytes: Int64
        let etag: String
    }

    /// オブジェクトをチャンク・ストリーミングで `tmpURL` へ書き込みつつ SHA-256 を逐次計算する。
    /// 大ファイル（files/...）の復元用。マニフェスト経路（`getObject(maxBytes:)` の 16MiB cap）とは別物で、
    /// こちらは原則サイズ無制限（メモリはチャンクで有界）。404 のとき nil を返す。
    /// 失敗時は書きかけの tmpURL を掃除する。SHA の検証（期待値との突合）は呼び出し側で行う。
    func downloadToFile(
        key: String,
        into tmpURL: URL,
        maxBytes: Int64? = nil
    ) async throws -> DownloadResult? {
        let input = GetObjectInput(bucket: bucket, key: key)
        do {
            let output = try await client.getObject(input: input)
            if let maxBytes, let len = output.contentLength, Int64(len) > maxBytes {
                throw SyncError.ioError(underlying: NSError(
                    domain: "Tide.S3", code: -22,
                    userInfo: [NSLocalizedDescriptionKey: "object too large: \(len) > \(maxBytes) bytes for key \(key)"]
                ))
            }
            let etag = Self.cleanETag(output.eTag)

            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmpURL)
            defer { try? handle.close() }

            var hasher = SHA256()
            var total: Int64 = 0
            func consume(_ data: Data) throws {
                guard !data.isEmpty else { return }
                total += Int64(data.count)
                if let maxBytes, total > maxBytes {
                    throw SyncError.ioError(underlying: NSError(
                        domain: "Tide.S3", code: -23,
                        userInfo: [NSLocalizedDescriptionKey: "downloaded body exceeds maxBytes: \(total) > \(maxBytes)"]
                    ))
                }
                hasher.update(data: data)
                try handle.write(contentsOf: data)
            }

            switch output.body {
            case .some(.stream(let stream)):
                while let chunk = try await stream.readAsync(upToCount: 1 << 20) {
                    if chunk.isEmpty { break }
                    try consume(chunk)
                }
            case .some(.data(let data)):
                if let data { try consume(data) }
            case .some(.noStream), .none:
                break
            }
            try handle.synchronize()
            return DownloadResult(sha256: HashCalculator.hex(hasher.finalize()), bytes: total, etag: etag)
        } catch let error as NoSuchKey {
            _ = error
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            // 404 系は nil（判定は S3ErrorClassifier.isNotFound に集約）
            if S3ErrorClassifier.isNotFound(error) { return nil }
            throw error
        }
    }

    // MARK: - Manifest

    struct ManifestFetch<T> {
        let value: T
        let etag: String
    }

    func getIndex() async throws -> ManifestFetch<ManifestIndex>? {
        // index.json は数百 KiB 程度のはず。16 MiB を上限に。
        guard let raw = try await getObject(key: ".tide/index.json", maxBytes: 16 * 1024 * 1024) else { return nil }
        let index = try ManifestJSON.decode(ManifestIndex.self, from: raw.data)
        return ManifestFetch(value: index, etag: raw.etag)
    }

    @discardableResult
    func putIndex(_ index: ManifestIndex, ifMatch: String?) async throws -> String {
        let data = try ManifestJSON.encode(index)
        let result = try await putObject(
            key: ".tide/index.json",
            data: data,
            contentType: "application/json",
            ifMatch: ifMatch,
            ifNoneMatch: ifMatch == nil ? "*" : nil
        )
        return result.etag
    }

    func getShard(_ id: String) async throws -> ManifestFetch<ManifestShard>? {
        try PathValidator.validateShardId(id)
        // 1 シャードあたり数百 KiB〜数 MiB 想定。16 MiB を上限。
        guard let raw = try await getObject(key: ".tide/shards/\(id).json", maxBytes: 16 * 1024 * 1024) else { return nil }
        let shard = try ManifestJSON.decode(ManifestShard.self, from: raw.data)
        return ManifestFetch(value: shard, etag: raw.etag)
    }

    @discardableResult
    func putShard(_ shard: ManifestShard, ifMatch: String?) async throws -> String {
        try PathValidator.validateShardId(shard.shardId)
        let data = try ManifestJSON.encode(shard)
        let result = try await putObject(
            key: ".tide/shards/\(shard.shardId).json",
            data: data,
            contentType: "application/json",
            ifMatch: ifMatch,
            ifNoneMatch: ifMatch == nil ? "*" : nil
        )
        return result.etag
    }

    func deleteShard(_ id: String) async throws {
        try PathValidator.validateShardId(id)
        try await deleteObject(key: ".tide/shards/\(id).json")
    }
}

/// S3 エラーのざっくり分類（型に依存せず文字列マッチで判定）。
enum S3ErrorClassifier {
    static func isPreconditionFailed(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("PreconditionFailed")
            || desc.contains("412")
            || desc.contains("ConditionalRequestFailed")
    }

    /// S3 の条件付き書き込み（If-Match / If-None-Match）が、同一キーへの並行操作と衝突したときに返る
    /// 409 `ConditionalRequestConflict`。412 PreconditionFailed と同様、再取得して PUT し直せば
    /// 解消する一時的失敗なので、楽観ロックの再試行対象に含める。
    static func isConditionalConflict(_ error: Error) -> Bool {
        String(describing: error).contains("ConditionalRequestConflict")
    }

    static func isNotFound(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("NotFound")
            || desc.contains("NoSuchBucket")
            || desc.contains("NoSuchKey")
            || desc.contains("statusCode: 404")
            || desc.contains("status code: 404")
    }

    static func isForbidden(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("Forbidden")
            || desc.contains("AccessDenied")
            || desc.contains("statusCode: 403")
            || desc.contains("status code: 403")
    }

    /// HeadBucket など HEAD 系が 404 以外の空ボディ応答（典型的に 403 / 301）を返すと、
    /// smithy-swift の `RestXMLError` が `<Code>` を読めず `BaseErrorDecodeError.missingRequiredData`
    /// を投げる（`RestXMLError.swift` の `code == nil && statusCode != .notFound` 分岐）。
    /// この decode エラーには HTTP ステータスが乗らないため、存在判定としては「不確定」扱いにする。
    /// （SDK のカスタマイズが空ボディ 404 のみ対象なのが根本原因。）
    static func isInconclusiveHeadError(_ error: Error) -> Bool {
        String(describing: error).contains("missingRequiredData")
    }

    /// CreateBucket が「既に存在し、かつ自分の所有」を返した（= そのまま使ってよい。複数マシン同期）。
    static func isBucketAlreadyOwnedByYou(_ error: Error) -> Bool {
        String(describing: error).contains("BucketAlreadyOwnedByYou")
    }

    /// CreateBucket が「その名前は他アカウントが使用中」を返した（= 同期に使えない）。
    /// `BucketAlreadyOwnedByYou` は別物（こちらには含まれない）。
    static func isBucketNameTaken(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("BucketAlreadyExists") && !desc.contains("BucketAlreadyOwnedByYou")
    }
}
