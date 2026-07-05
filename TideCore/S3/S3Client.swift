import Foundation
import CryptoKit
@preconcurrency import AWSS3
@preconcurrency import AWSSDKIdentity
@preconcurrency import Smithy
@preconcurrency import SmithyHTTPAPI

/// AWS SDK for Swift の S3Client をラップした薄い層。
public final class TideS3Client: @unchecked Sendable {
    public let bucket: String
    public let region: String
    public let deviceId: String
    private let client: AWSS3.S3Client

    public init(credentials: AWSCredentials, region: String, bucket: String, deviceId: String) throws {
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
    public func headBucket() async throws {
        let input = HeadBucketInput(bucket: bucket)
        _ = try await client.headBucket(input: input)
    }

    public func checkBucketAccess() async throws {
        do {
            try await headBucket()
        } catch {
            throw SyncError.bucketNotAccessible(reason: String(describing: error))
        }
    }

    /// 新規バケットを作成する。us-east-1 では locationConstraint を付けない。
    public func createBucket() async throws {
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

    public func isVersioningEnabled() async throws -> Bool {
        let input = GetBucketVersioningInput(bucket: bucket)
        let output = try await client.getBucketVersioning(input: input)
        return output.status == .enabled
    }

    public func enableVersioning() async throws {
        let input = PutBucketVersioningInput(
            bucket: bucket,
            versioningConfiguration: S3ClientTypes.VersioningConfiguration(status: .enabled)
        )
        _ = try await client.putBucketVersioning(input: input)
    }

    /// Block Public Access を 4 つの設定全部 true で投入。
    /// 既に同じ設定でも冪等（PUT セマンティクス）。
    public func enforcePublicAccessBlock() async throws {
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

    public enum TLSPolicyStatus: Sendable {
        case alreadyEnforced
        case updated
    }

    /// TLS 非使用リクエストを拒否する Deny ポリシー（C3 後半・Issue #26 / B）を冪等にマージして投入する。
    /// `getBucketPolicy`（`NoSuchBucketPolicy`/notFound は空扱い）→ `BucketPolicyBuilder` で Tide の statement
    /// （`Sid: TideDenyInsecureTransport`）だけ差し替え（他は保持）→ `putBucketPolicy`。既に同内容で入って
    /// いれば put しない（毎起動の無駄な書込を避ける）。多層防御（SDK 既定 HTTPS）なので呼び出し側は非致命に扱う。
    /// Block Public Access の後に呼んでよい（Deny statement は "public" 判定にならず `blockPublicPolicy` に弾かれない）。
    @discardableResult
    public func enforceTLSBucketPolicy() async throws -> TLSPolicyStatus {
        let current: String?
        do {
            let output = try await client.getBucketPolicy(input: GetBucketPolicyInput(bucket: bucket))
            current = output.policy
        } catch {
            if String(describing: error).contains("NoSuchBucketPolicy")
                || S3ErrorClassifier.isNotFound(error) {
                current = nil
            } else {
                throw error
            }
        }
        if BucketPolicyBuilder.isTLSDenyEnforced(in: current, bucket: bucket) {
            return .alreadyEnforced
        }
        let merged = try BucketPolicyBuilder.mergeTLSDenyStatement(into: current, bucket: bucket)
        _ = try await client.putBucketPolicy(
            input: PutBucketPolicyInput(bucket: bucket, policy: merged)
        )
        return .updated
    }

    public enum LifecycleStatus: Sendable {
        case alreadyConfigured
        case updated
    }

    /// Tide が必要とする 3 ルール（abort multipart / expire old versions / expire delete markers）が
    /// 既に揃っていればそのまま返す。揃っていなければ「ユーザ独自ルール + Tide 3 ルール」をマージして PUT する。
    ///
    /// `tide-...` の ID を持つ既存ルールは Tide のものとみなし、内容を最新の定義に差し替える。
    /// それ以外のユーザ独自ルールはすべて温存する。
    @discardableResult
    public func ensureLifecycleRules() async throws -> LifecycleStatus {
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

    public struct PutObjectResult: Sendable {
        public let etag: String
        public let versionId: String?

        public init(etag: String, versionId: String?) {
            self.etag = etag
            self.versionId = versionId
        }
    }

    /// S3 が返す ETag は両端がダブルクォートで囲まれているので外す（全 API 共通の整形）。
    private static func cleanETag(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    public func putObject(
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

    public func deleteObject(key: String) async throws {
        let input = DeleteObjectInput(bucket: bucket, key: key)
        _ = try await client.deleteObject(input: input)
    }

    public struct ObjectHead: Sendable {
        public let etag: String
        public let versionId: String?
        public let size: Int64?
        public let metadata: [String: String]

        public init(etag: String, versionId: String?, size: Int64?, metadata: [String: String]) {
            self.etag = etag
            self.versionId = versionId
            self.size = size
            self.metadata = metadata
        }
    }

    /// オブジェクトのメタデータのみ取得する。404 → nil。
    /// `versionId` を渡すとその特定バージョンの HEAD を取る（復元の真実サイズ取得に使う）。
    public func headObject(key: String, versionId: String? = nil) async throws -> ObjectHead? {
        var input = HeadObjectInput(bucket: bucket, key: key)
        if let versionId { input.versionId = versionId }
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

    public struct ObjectFetch: Sendable {
        public let data: Data
        public let etag: String

        public init(data: Data, etag: String) {
            self.data = data
            self.etag = etag
        }
    }

    /// オブジェクトを取得する。`maxBytes` を指定するとレスポンスサイズの自己防衛が効く
    /// （膨大な `.tide/index.json` などで OOM を起こさせない）。
    public func getObject(key: String, maxBytes: Int64 = 200 * 1024 * 1024, versionId: String? = nil) async throws -> ObjectFetch? {
        var input = GetObjectInput(bucket: bucket, key: key)
        if let versionId { input.versionId = versionId }
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
    public func createMultipartUpload(
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
    public func uploadPart(
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
    public func completeMultipartUpload(
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
    public func abortMultipartUpload(key: String, uploadId: String) async throws {
        let input = AbortMultipartUploadInput(bucket: bucket, key: key, uploadId: uploadId)
        _ = try await client.abortMultipartUpload(input: input)
    }

    // MARK: - Streaming download

    public struct StreamObjectResult: Sendable {
        /// クォート除去済みの ETag。
        public let etag: String
        /// サーバ申告の本体長（Range 指定時は残り長。あくまで参考値）。
        public let contentLength: Int64?

        public init(etag: String, contentLength: Int64?) {
            self.etag = etag
            self.contentLength = contentLength
        }
    }

    /// `key` を GetObject（`rangeStart` 指定時は `Range: bytes=rangeStart-`）し、本体チャンクを
    /// 順に `sink` へ渡す。ファイル書込・SHA 計算・サイズ上限の判定は呼び出し側（`Downloader`）が
    /// `sink` の中で行う（再開のためのハッシュ前置きと進捗 checkpoint を呼び出し側で握りやすくするため）。
    /// 404 のとき nil。`sink` が throw したらそのまま伝播する（tmp の後始末は呼び出し側）。
    ///
    /// `limiter` を渡すと、各チャンクを `sink` へ渡す前に帯域制御 actor から許可を取り、消費（＝読込）
    /// 速度を律速する。読込を遅らせると下層の TCP フロー制御でサーバ送出も自然に絞られる（サブ E）。
    public func streamObject(
        key: String,
        rangeStart: Int64?,
        limiter: RateLimiter? = nil,
        sink: (Data) throws -> Void
    ) async throws -> StreamObjectResult? {
        try await streamObject(
            key: key, versionId: nil, rangeStart: rangeStart, limiter: limiter, sink: sink
        )
    }

    /// `versionId` 指定でストリーミング取得する（復元の履歴 DL 用）。versionId なし = 最新版。
    /// 404 / `NoSuchVersion` のとき nil。挙動は versionId なし版と同じ（`input.versionId` を足すだけ）。
    public func streamObject(
        key: String,
        versionId: String?,
        rangeStart: Int64?,
        limiter: RateLimiter? = nil,
        sink: (Data) throws -> Void
    ) async throws -> StreamObjectResult? {
        var input = GetObjectInput(bucket: bucket, key: key)
        if let versionId { input.versionId = versionId }
        if let rangeStart, rangeStart > 0 {
            input.range = "bytes=\(rangeStart)-"
        }
        do {
            let output = try await client.getObject(input: input)
            let etag = Self.cleanETag(output.eTag)
            let contentLength = output.contentLength.map(Int64.init)
            switch output.body {
            case .some(.stream(let stream)):
                while let chunk = try await stream.readAsync(upToCount: 1 << 20) {
                    if chunk.isEmpty { break }
                    await limiter?.acquire(chunk.count)
                    try sink(chunk)
                }
            case .some(.data(let data)):
                if let data, !data.isEmpty {
                    await limiter?.acquire(data.count)
                    try sink(data)
                }
            case .some(.noStream), .none:
                break
            }
            return StreamObjectResult(etag: etag, contentLength: contentLength)
        } catch let error as NoSuchKey {
            _ = error
            return nil
        } catch {
            // 404 系は nil（判定は S3ErrorClassifier.isNotFound に集約）
            if S3ErrorClassifier.isNotFound(error) { return nil }
            throw error
        }
    }

    // MARK: - Object versions（バージョン履歴 / 削除済み復元）

    /// `ListObjectVersions` の 1 ページぶんを Tide 独自の Sendable 値へ詰め替えたもの。
    /// 生 SDK 型（`S3ClientTypes.ObjectVersion` / `DeleteMarkerEntry`）を UI / ロジックへ漏らさない。
    public struct S3ObjectVersionRaw: Sendable {
        public let key: String
        public let versionId: String?
        public let isLatest: Bool
        public let size: Int64?
        public let lastModified: Date?
        public let etag: String

        public init(key: String, versionId: String?, isLatest: Bool, size: Int64?, lastModified: Date?, etag: String) {
            self.key = key
            self.versionId = versionId
            self.isLatest = isLatest
            self.size = size
            self.lastModified = lastModified
            self.etag = etag
        }
    }

    public struct S3DeleteMarkerRaw: Sendable {
        public let key: String
        public let versionId: String?
        public let isLatest: Bool
        public let lastModified: Date?

        public init(key: String, versionId: String?, isLatest: Bool, lastModified: Date?) {
            self.key = key
            self.versionId = versionId
            self.isLatest = isLatest
            self.lastModified = lastModified
        }
    }

    public struct ObjectVersionPage: Sendable {
        public let versions: [S3ObjectVersionRaw]
        public let deleteMarkers: [S3DeleteMarkerRaw]
        /// 次ページのカーソル（`isTruncated` が true のとき有効）。
        public let nextKeyMarker: String?
        public let nextVersionIdMarker: String?
        public let isTruncated: Bool

        public init(versions: [S3ObjectVersionRaw], deleteMarkers: [S3DeleteMarkerRaw], nextKeyMarker: String?, nextVersionIdMarker: String?, isTruncated: Bool) {
            self.versions = versions
            self.deleteMarkers = deleteMarkers
            self.nextKeyMarker = nextKeyMarker
            self.nextVersionIdMarker = nextVersionIdMarker
            self.isTruncated = isTruncated
        }
    }

    /// `prefix` 配下のオブジェクトバージョンと delete marker を 1 ページぶん列挙する。
    /// `keyMarker` / `versionIdMarker` に前ページの `next*` を渡すと続きを取得できる。
    public func listObjectVersions(
        prefix: String,
        keyMarker: String? = nil,
        versionIdMarker: String? = nil,
        maxKeys: Int = 1000
    ) async throws -> ObjectVersionPage {
        let input = ListObjectVersionsInput(
            bucket: bucket,
            keyMarker: keyMarker,
            maxKeys: maxKeys,
            prefix: prefix,
            versionIdMarker: versionIdMarker
        )
        let output = try await client.listObjectVersions(input: input)
        let versions: [S3ObjectVersionRaw] = (output.versions ?? []).compactMap { v in
            guard let key = v.key else { return nil }
            return S3ObjectVersionRaw(
                key: key,
                versionId: v.versionId,
                isLatest: v.isLatest ?? false,
                size: v.size.map(Int64.init),
                lastModified: v.lastModified,
                etag: Self.cleanETag(v.eTag)
            )
        }
        let markers: [S3DeleteMarkerRaw] = (output.deleteMarkers ?? []).compactMap { m in
            guard let key = m.key else { return nil }
            return S3DeleteMarkerRaw(
                key: key,
                versionId: m.versionId,
                isLatest: m.isLatest ?? false,
                lastModified: m.lastModified
            )
        }
        return ObjectVersionPage(
            versions: versions,
            deleteMarkers: markers,
            nextKeyMarker: output.nextKeyMarker,
            nextVersionIdMarker: output.nextVersionIdMarker,
            isTruncated: output.isTruncated ?? false
        )
    }

    // MARK: - Manifest

    public struct ManifestFetch<T> {
        public let value: T
        public let etag: String

        public init(value: T, etag: String) {
            self.value = value
            self.etag = etag
        }
    }

    public func getIndex() async throws -> ManifestFetch<ManifestIndex>? {
        // index.json は数百 KiB 程度のはず。16 MiB を上限に。
        guard let raw = try await getObject(key: ".tide/index.json", maxBytes: 16 * 1024 * 1024) else { return nil }
        let index = try ManifestJSON.decode(ManifestIndex.self, from: raw.data)
        return ManifestFetch(value: index, etag: raw.etag)
    }

    @discardableResult
    public func putIndex(_ index: ManifestIndex, ifMatch: String?) async throws -> String {
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

    public func getShard(_ id: String) async throws -> ManifestFetch<ManifestShard>? {
        try PathValidator.validateShardId(id)
        // 1 シャードあたり数百 KiB〜数 MiB 想定。16 MiB を上限。
        guard let raw = try await getObject(key: ".tide/shards/\(id).json", maxBytes: 16 * 1024 * 1024) else { return nil }
        let shard = try ManifestJSON.decode(ManifestShard.self, from: raw.data)
        return ManifestFetch(value: shard, etag: raw.etag)
    }

    @discardableResult
    public func putShard(_ shard: ManifestShard, ifMatch: String?) async throws -> String {
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

    public func deleteShard(_ id: String) async throws {
        try PathValidator.validateShardId(id)
        try await deleteObject(key: ".tide/shards/\(id).json")
    }
}

/// S3 エラーのざっくり分類（型に依存せず文字列マッチで判定）。
public enum S3ErrorClassifier {
    public static func isPreconditionFailed(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("PreconditionFailed")
            || desc.contains("412")
            || desc.contains("ConditionalRequestFailed")
    }

    /// S3 の条件付き書き込み（If-Match / If-None-Match）が、同一キーへの並行操作と衝突したときに返る
    /// 409 `ConditionalRequestConflict`。412 PreconditionFailed と同様、再取得して PUT し直せば
    /// 解消する一時的失敗なので、楽観ロックの再試行対象に含める。
    public static func isConditionalConflict(_ error: Error) -> Bool {
        String(describing: error).contains("ConditionalRequestConflict")
    }

    public static func isNotFound(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("NotFound")
            || desc.contains("NoSuchBucket")
            || desc.contains("NoSuchKey")
            || desc.contains("NoSuchVersion")
            || desc.contains("statusCode: 404")
            || desc.contains("status code: 404")
    }

    /// マルチパートの UploadId が無効（完了済み / abort 済み / 7 日ライフサイクル失効）のとき
    /// S3 が complete/uploadPart に返す `NoSuchUpload`。
    /// NB: S3 ではこれも HTTP 404 で返るため `isNotFound` とも一致し得る。再開時の stale UploadId
    /// 判定として、コード文字列で明示的に切り分ける（NoSuchKey 等の一般 404 と混同しない）。
    public static func isNoSuchUpload(_ error: Error) -> Bool {
        String(describing: error).contains("NoSuchUpload")
    }

    public static func isForbidden(_ error: Error) -> Bool {
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
    public static func isInconclusiveHeadError(_ error: Error) -> Bool {
        String(describing: error).contains("missingRequiredData")
    }

    /// CreateBucket が「既に存在し、かつ自分の所有」を返した（= そのまま使ってよい。複数マシン同期）。
    public static func isBucketAlreadyOwnedByYou(_ error: Error) -> Bool {
        String(describing: error).contains("BucketAlreadyOwnedByYou")
    }

    /// CreateBucket が「その名前は他アカウントが使用中」を返した（= 同期に使えない）。
    /// `BucketAlreadyOwnedByYou` は別物（こちらには含まれない）。
    public static func isBucketNameTaken(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("BucketAlreadyExists") && !desc.contains("BucketAlreadyOwnedByYou")
    }
}

// ManifestStore / ManifestSnapshotSource を actor で実装（テストのフェイク等）しても
// isolation 境界を越えて返せるように、中身が Sendable なら Sendable（M5 Phase 5-0）。
// 実運用の T は ManifestIndex / ManifestShard（ともに Sendable）のみ。
extension TideS3Client.ManifestFetch: Sendable where T: Sendable {}
