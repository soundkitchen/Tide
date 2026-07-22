import Foundation
import CryptoKit

/// S3 内復元（M5 Track B-2）の PUT レグ最小シーム（単発 PUT + マルチパート）。
/// 本番は `TideS3Client` が適合し、テストはフェイクで PUT 呼び出しと競合注入を検証する。
/// `MultipartUploadClient` を継承するので `MultipartUploader` にそのまま渡せる。
public protocol RestorePutClient: MultipartUploadClient {
    func putObject(
        key: String,
        data: Data,
        contentType: String,
        metadata: [String: String],
        ifMatch: String?,
        ifNoneMatch: String?
    ) async throws -> TideS3Client.PutObjectResult
}

extension TideS3Client: RestorePutClient {}

/// `S3RestoreService.restore` の結果。
public enum S3RestoreOutcome: Sendable, Equatable {
    /// 選んだ版を新しい現行版としてマニフェストへ書いた
    /// （FP レプリカへは `onManifestDidWrite` → signal → enumerateChanges で伝播する）。
    case restored
    /// 選んだ版の内容が既に現行と同一だった（PUT もマニフェスト書込もしない no-op。
    /// `updateFileEntry` が `.alreadyUpToDate` を返した＝並行書き手が同一内容を確定済みの場合も含む）。
    case alreadyCurrent
}

/// FP-only 稼働モード（M5 Track B-2）の「S3 内復元」: 選んだ過去版を S3 の新しい現行版として
/// 書き直す。**ローカル syncRoot / DB には一切触れない**（fpOnly の凍結温存の不変条件を維持。
/// tmp は Caches 側のみ使う）。
///
/// 方式（ユーザ確定 2026-07-22）: tmp DL → 現行版 PUT → `ManifestUpdater.updateFileEntry` 合流。
/// マニフェスト書込が共有チョークポイント（拡張・アプリと同一）を通るため、並行更新の検出
/// （`decideUpload` = ベースは復元開始時点の現行 entry sha）と FP レプリカへの伝播は既存機構に乗る。
/// 競合時は `SyncError.uploadConflict` がそのまま伝播し、本体 PUT 済みの版は「マニフェスト外の
/// 不可視 live 版」として残る（アプリのアップロード競合と同じ特性・版履歴で回収可・データ損失なし）。
///
/// 過去版にはマニフェスト sha256 が無い（マニフェストは現行状態のみ）ため、DL の整合性は
/// `RestoreService` と同じく `headObject(versionId:)` の真実サイズで担保する。新 entry の sha256 は
/// アップロード時に実際に読んだバイト列から計算する。
public struct S3RestoreService: Sendable {
    /// HEAD / ストリーミング GET（DL レグ）。`RestoreService` と同じシーム。
    public let client: any VersionedObjectClient
    /// PUT レグ（単発 + マルチパート）。SSE-S3 は `putObject` / MPU 実装側で常時付与される。
    public let put: any RestorePutClient
    /// マニフェスト書込の共有チョークポイント。呼び出し側が `onManifestDidWrite` に
    /// FP signal を配線して渡す（新 entry の deviceId もここから取る = 正本を 1 つに保つ）。
    public let updater: ManifestUpdater
    public let tmpDir: URL
    /// アップロード上限（<= 0 は無制限）。復元は再アップロードを伴うため folderSync と同じ規約で守る。
    public let uploadSizeLimitBytes: Int64
    public var downloadLimiter: RateLimiter? = nil
    public var uploadLimiter: RateLimiter? = nil

    public init(
        client: any VersionedObjectClient,
        put: any RestorePutClient,
        updater: ManifestUpdater,
        tmpDir: URL,
        uploadSizeLimitBytes: Int64,
        downloadLimiter: RateLimiter? = nil,
        uploadLimiter: RateLimiter? = nil
    ) {
        self.client = client
        self.put = put
        self.updater = updater
        self.tmpDir = tmpDir
        self.uploadSizeLimitBytes = uploadSizeLimitBytes
        self.downloadLimiter = downloadLimiter
        self.uploadLimiter = uploadLimiter
    }

    /// サイズ上限超過など「破棄して仕切り直すべき」失敗。
    private enum RestoreAbort: Error {
        case tooLarge
    }

    /// `relativePath` の `versionId`（nil = 最新版）を S3 の新しい現行版として書き直す。
    @discardableResult
    public func restore(relativePath: String, versionId: String?) async throws -> S3RestoreOutcome {
        // リモート由来 key の再検証（UI 側で検証済みでも入口で必ず通す）。
        try PathValidator.validateRelativePath(relativePath)
        let s3Key = "files/\(relativePath)"

        // 1. HEAD で真実サイズを取得（履歴版にマニフェスト entry.size が無いため）。
        guard let head = try await client.headObject(key: s3Key, versionId: versionId) else {
            throw Self.serviceError(code: -50, "version not found on S3 for key \(s3Key)")
        }
        guard let expectedSize = head.size, expectedSize >= 0 else {
            throw Self.serviceError(code: -51, "missing content length for key \(s3Key)")
        }
        // 2. 復元は再アップロードを伴うので、DL 前にアップロード上限で先に弾く（帯域と tmp を無駄にしない）。
        guard PartPlan.isWithinUploadLimit(size: expectedSize, limitBytes: uploadSizeLimitBytes) else {
            throw SyncError.fileTooLarge(path: relativePath, size: expectedSize)
        }

        // 3. 3-way ベース = 復元開始時点の現行マニフェスト entry の sha
        //    （無ければ削除済み/未追跡 = base nil の新規作成側で decideUpload に合流）。
        let shardId = ManifestSharding.shardId(for: relativePath)
        let baseSha = try await updater.store.getShard(shardId)?.value.files[relativePath]?.sha256

        // 4. tmp へストリーミング DL（走りながら sha256・真実サイズ超過は即破棄）。
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpURL = restoreTmpURL(for: relativePath, versionId: versionId)
        try? FileManager.default.removeItem(at: tmpURL)  // 残骸があれば消す（O_EXCL で fresh 作成するため）
        // tmp は S3 へ PUT した後に消すだけ（move 先が無い）ので、成功・失敗を問わず必ず後始末する。
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let handle = try Downloader.openTmpForWriting(at: tmpURL, append: false)
        var hasher = SHA256()
        var total: Int64 = 0
        do {
            let result = try await client.streamObject(
                key: s3Key, versionId: versionId, rangeStart: nil, limiter: downloadLimiter
            ) { chunk in
                total += Int64(chunk.count)
                if total > expectedSize { throw RestoreAbort.tooLarge }
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
            }
            try handle.synchronize()
            try handle.close()
            guard result != nil else {
                throw Self.serviceError(code: -50, "version not found on S3 for key \(s3Key)")
            }
        } catch is RestoreAbort {
            try? handle.close()
            AppLogger.s3.error("S3 restore exceeded expected size: \(relativePath, privacy: .private)")
            throw Self.serviceError(code: -52, "restored body exceeds expected size for key \(s3Key)")
        } catch {
            try? handle.close()
            throw error
        }

        // 5. 実サイズ突合（HEAD のサイズと一致しなければ破棄）。
        let actualSize = Downloader.fileSize(at: tmpURL) ?? -1
        guard actualSize == expectedSize else {
            AppLogger.s3.error("S3 restore size mismatch (\(actualSize) != \(expectedSize)): \(relativePath, privacy: .private)")
            throw Self.serviceError(code: -53, "restored file size mismatch for key \(s3Key)")
        }
        let downloadedSha = HashCalculator.hex(hasher.finalize())

        // 6. 現行と同一内容なら何もしない（無駄な版チャーンとマニフェスト書込を避ける）。
        if let baseSha, baseSha == downloadedSha {
            AppLogger.sync.info("S3 restore no-op (already current): \(relativePath, privacy: .private)")
            return .alreadyCurrent
        }

        // 7. 本体 PUT（単発 or マルチパート・SSE-S3 は実装側で常時付与）。tmp は自分専用の静止
        //    ファイルだが、規約どおり `NoFollowFileReader` の単一 FD から読む（多層防御）。
        let reader = try NoFollowFileReader(path: tmpURL.path)
        defer { reader.close() }
        let info = try reader.info()
        let putResult: TideS3Client.PutObjectResult
        let uploadedSha: String
        if PartPlan.shouldUseMultipart(fileSize: info.size) {
            let plan = PartPlan.plan(forFileSize: info.size)
            let result = try await MultipartUploader(s3: put).upload(
                key: s3Key, reader: reader, partSize: plan.partSize, limiter: uploadLimiter
            )
            putResult = result.put
            uploadedSha = result.sha256
        } else {
            let (data, hash) = try HashCalculator.readAllAndHash(reader)
            if let uploadLimiter { await uploadLimiter.acquire(data.count) }
            putResult = try await put.putObject(
                key: s3Key, data: data, contentType: "application/octet-stream",
                metadata: [:], ifMatch: nil, ifNoneMatch: nil
            )
            uploadedSha = hash
        }

        // 8. マニフェスト合流（共有チョークポイント）。mtime は復元時刻 = now（ユーザ確定
        //    2026-07-23・folderSync 復元 = ローカル書き戻し後の再アップロードが stat 実値 =
        //    復元時刻を記録するのと対称）。競合（uploadConflict）はそのまま伝播する。
        let entry = ManifestFileEntry(
            size: info.size,
            mtime: ISO8601.format(Date()),
            sha256: uploadedSha,
            s3VersionId: putResult.versionId,
            etag: putResult.etag,
            deviceId: updater.deviceId,
            uploadedAt: ISO8601.now()
        )
        let outcome = try await updater.updateFileEntry(
            for: relativePath, base: baseSha, newEntry: entry
        )
        switch outcome {
        case .wrote:
            AppLogger.sync.info(
                "S3 restore wrote new current version: \(relativePath, privacy: .private) (bytes=\(actualSize))"
            )
            return .restored
        case .alreadyUpToDate:
            // 並行書き手が同一内容を確定済み（自分の PUT は不可視 live 版として残る・無害）。
            AppLogger.sync.info("S3 restore already up to date: \(relativePath, privacy: .private)")
            return .alreadyCurrent
        }
    }

    // MARK: - helpers

    /// 復元専用の決定的 tmp 名。`Downloader` の `dl-...` / `RestoreService` の `restore-...` とも、
    /// 別 versionId の復元とも衝突しないよう対象相対パス + versionId をハッシュする。
    private func restoreTmpURL(for relativePath: String, versionId: String?) -> URL {
        let seed = "\(relativePath)\u{0}\(versionId ?? "latest")"
        let h = HashCalculator.hex(SHA256.hash(data: Data(seed.utf8)))
        return tmpDir.appendingPathComponent("s3restore-\(h).part")
    }

    private static func serviceError(code: Int, _ message: String) -> SyncError {
        SyncError.ioError(underlying: NSError(
            domain: "Tide.S3RestoreService", code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
