import Foundation
import GRDB

/// 単一ファイルのアップロード / 削除と、それに伴うマニフェスト・DB 更新をまとめた処理。
struct Uploader {
    let s3: TideS3Client
    let db: LocalDatabase
    let syncRoot: URL
    let deviceId: String
    /// 1 ファイルあたりのアップロード上限を都度参照する（Settings 変更を次の処理で反映）。
    let config: ConfigStore
    /// 中断・再開（サブ D）の checkpoint 永続化。マルチパート経路でのみ使う。
    let transferStore: any TransferStateStoring
    /// 進捗報告（メニューバー表示用）。マルチパート経路でのみ発行する。nil 可。
    var progressReporter: TransferProgressReporter? = nil

    /// upload_queue の 1 件を処理する。
    func process(_ item: UploadQueueRecord) async throws {
        switch item.operation {
        case "upload":
            try await processUpload(item)
        case "delete":
            try await processDelete(item)
        default:
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.Uploader",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "unknown operation \(item.operation)"]
            ))
        }
    }

    private func processUpload(_ item: UploadQueueRecord) async throws {
        let path = item.path
        // 念のため入口で再検証（FileWatcher 由来でもキュー再起動でも経由する）
        try PathValidator.validateRelativePath(path)
        let fullURL = try PathValidator.resolveSafely(relativePath: path, syncRoot: syncRoot)

        // M5 (F3 / L9): O_NOFOLLOW で 1 回だけ open する。
        // - 最終コンポーネントが symlink なら ELOOP → 拒否してキューから外す（リンク先実体を S3 へ送らない）。
        // - 以後のハッシュ計算と本体読込はすべてこの同一 FD から行うので「ハッシュ用 open → 本体用 open」の
        //   2 回 open に存在した TOCTOU 窓が無くなる（祖先 symlink は resolveSafely とスキャンの skip に委ねる）。
        let reader: NoFollowFileReader
        do {
            reader = try NoFollowFileReader(path: fullURL.path)
        } catch FileOpenError.isSymbolicLink {
            // symlink への差し替えを検知 → キュー除去に留める（誤ってリモートの正データを消さない）。
            // L6: 処理した行 (id) だけを消す。処理中に新イベントが INSERT OR REPLACE で作った
            // 新 id の行（別内容の再アップロード指示）を path 基準で巻き込み削除しないため。
            try await db.pool.write { db in
                try UploadQueueRecord
                    .filter(Column("id") == item.id)
                    .deleteAll(db)
                var log = SyncLogRecord(
                    id: nil,
                    timestamp: Date().timeIntervalSince1970,
                    eventType: "error",
                    path: path,
                    message: "Refusing to upload a symbolic link (skipped)",
                    details: nil
                )
                try log.insert(db)
            }
            AppLogger.sync.error("Refusing to upload a symbolic link: \(path, privacy: .private)")
            return
        } catch FileOpenError.notFound {
            // 読み込みタイミングで削除された → delete として再処理
            try await convertQueueItemToDelete(item)
            return
        }
        defer { reader.close() }

        // 1. attribute（同一 FD を fstat）
        let info = try reader.info()
        let size = info.size
        let mtimeDate = info.mtime
        let mtime = mtimeDate.timeIntervalSince1970

        // 1 ファイルあたりのアップロード上限。超過は黙ってスキップせず fileTooLarge を投げ、
        // SyncEngine 側でリトライせずに recentErrors へ明示 + キュー除去する（「バックアップされていない」可視化）。
        let limit = config.uploadSizeLimitBytes
        guard PartPlan.isWithinUploadLimit(size: size, limitBytes: limit) else {
            throw SyncError.fileTooLarge(path: path, size: size)
        }

        // 2. hash + S3 upload（sha256 は CreateMultipartUpload 時点で未確定なので object metadata には載せない。
        //    整合性の真実は ManifestFileEntry.sha256。metadata は mtime / device / size のみ）。
        let metadata: [String: String] = [
            "mtime": ISO8601.format(mtimeDate),
            "device": deviceId,
            "size": String(size)
        ]
        let s3Key = "files/\(path)"

        let sha256: String
        let result: TideS3Client.PutObjectResult
        if PartPlan.shouldUseMultipart(fileSize: size) {
            let plan = PartPlan.plan(forFileSize: size)
            // 中断・再開: 同一ファイル（mtime/size 一致）なら前回の途中から再開する。
            let resume = MultipartUploader.ResumeContext(
                path: path, fileMtime: mtime, fileSize: size, store: transferStore
            )
            // 進捗報告（大ファイルのマルチパートのみ。begin → パート完了ごと update → end）。
            let reporter = progressReporter
            reporter?(.begin(path: path, direction: .upload, totalBytes: size))
            defer { reporter?(.end(path: path, direction: .upload)) }
            let onProgress: (@Sendable (Int64) -> Void)?
            if let reporter {
                onProgress = { @Sendable bytes in
                    reporter(.update(path: path, direction: .upload, transferredBytes: bytes))
                }
            } else {
                onProgress = nil
            }
            let mp = try await MultipartUploader(s3: s3).upload(
                key: s3Key,
                reader: reader,
                partSize: plan.partSize,
                metadata: metadata,
                resume: resume,
                onProgress: onProgress
            )
            sha256 = mp.sha256
            result = mp.put
        } else {
            // シングルパート: 同一 FD から 1 回読んだバッファでハッシュも本体も賄う（2 回 open を畳む）。
            let (data, sha) = try HashCalculator.readAllAndHash(reader)
            sha256 = sha
            result = try await s3.putObject(
                key: s3Key,
                data: data,
                contentType: "application/octet-stream",
                metadata: metadata
            )
        }
        AppLogger.s3.info("Uploaded \(path, privacy: .private) (\(size) bytes)")

        // 3. manifest update
        try await ManifestUpdater(s3: s3, deviceId: deviceId).updateShard(
            for: path
        ) { shard in
            shard.files[path] = ManifestFileEntry(
                size: size,
                mtime: ISO8601.format(mtimeDate),
                sha256: sha256,
                s3VersionId: result.versionId,
                etag: result.etag,
                deviceId: deviceId,
                uploadedAt: ISO8601.now()
            )
        }

        // 4. local DB
        let now = Date().timeIntervalSince1970
        try await db.pool.write { db in
            var rec = FileRecord(
                path: path,
                size: size,
                mtime: mtime,
                sha256: sha256,
                s3VersionId: result.versionId,
                s3Etag: result.etag,
                lastSyncedAt: now,
                updatedAt: now
            )
            try rec.save(db)
            // L6: 完了したこの行 (item.id) だけを消す。アップロード中に同 path へ新イベントが届くと
            // INSERT OR REPLACE で新 id の行に置換される（＝完全版を上げ直せ、という正当な指示）。
            // path 基準で消すとその新行まで巻き込み、ローカル≠DB≠リモートの無エラー乖離になっていた。
            // id 基準なら新行は残り、次周回で再アップロードされて自己修復する。
            try UploadQueueRecord
                .filter(Column("id") == item.id)
                .deleteAll(db)
            var log = SyncLogRecord(
                id: nil,
                timestamp: now,
                eventType: "upload",
                path: path,
                message: "Uploaded \(size) bytes",
                details: nil
            )
            try log.insert(db)
        }
    }

    private func processDelete(_ item: UploadQueueRecord) async throws {
        let path = item.path
        try PathValidator.validateRelativePath(path)
        let s3Key = "files/\(path)"

        try await s3.deleteObject(key: s3Key)
        AppLogger.s3.info("Deleted (delete marker): \(path, privacy: .private)")

        try await ManifestUpdater(s3: s3, deviceId: deviceId).updateShard(for: path) { shard in
            shard.files.removeValue(forKey: path)
        }

        let now = Date().timeIntervalSince1970
        try await db.pool.write { db in
            try FileRecord.deleteOne(db, key: path)
            // L6: 処理したこの行 (item.id) だけを消す（path 基準だと、削除処理中に再作成されて
            // 置換された新 id の upload 行を巻き込んでしまう）。
            try UploadQueueRecord
                .filter(Column("id") == item.id)
                .deleteAll(db)
            var log = SyncLogRecord(
                id: nil,
                timestamp: now,
                eventType: "delete",
                path: path,
                message: "Deleted",
                details: nil
            )
            try log.insert(db)
        }
    }

    private func convertQueueItemToDelete(_ item: UploadQueueRecord) async throws {
        try await db.pool.write { db in
            // L6: この行 (item.id) が処理中に新イベントで置換されている場合は、新 id の行が既に
            // 正しい次の指示を表しているので何もしない（古い item をそのまま update すると
            // recordNotFound になる、または置換された新行を取り違えて上書きしてしまう）。
            if var existing = try UploadQueueRecord
                .filter(Column("id") == item.id)
                .fetchOne(db) {
                existing.operation = "delete"
                try existing.update(db)
            }
        }
        AppLogger.sync.info("Converted queue item to delete: \(item.path, privacy: .private)")
    }
}

/// シャードと index.json を楽観的ロックで更新する。
struct ManifestUpdater {
    let s3: TideS3Client
    let deviceId: String

    func updateShard(
        for path: String,
        transform: (inout ManifestShard) -> Void
    ) async throws {
        let shardId = ManifestSharding.shardId(for: path)
        var lastError: Error?

        for _ in 0..<5 {
            do {
                let fetched = try await s3.getShard(shardId)
                var shard = fetched?.value ?? ManifestShard.empty(id: shardId)
                let etag = fetched?.etag
                transform(&shard)
                shard.updatedAt = ISO8601.now()

                if shard.files.isEmpty {
                    if etag != nil {
                        try await s3.deleteShard(shardId)
                    }
                    try await updateIndex { idx in
                        idx.shards.removeValue(forKey: shardId)
                    }
                    return
                }

                let newEtag = try await s3.putShard(shard, ifMatch: etag)
                try await updateIndex { idx in
                    idx.shards[shardId] = .init(etag: newEtag, count: shard.files.count)
                }
                return
            } catch {
                // 412 PreconditionFailed / 409 ConditionalRequestConflict は同一シャードへの
                // 並行更新による一時的失敗。再取得して PUT し直せば解消するのでリトライ。
                if S3ErrorClassifier.isPreconditionFailed(error)
                    || S3ErrorClassifier.isConditionalConflict(error) {
                    lastError = error
                    let nanos = UInt64.random(in: 100_000_000...500_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                    continue
                }
                throw error
            }
        }
        throw SyncError.manifestUpdateFailed(
            "shard \(shardId) conditional update failed 5 times: \(String(describing: lastError))"
        )
    }

    private func updateIndex(_ transform: (inout ManifestIndex) -> Void) async throws {
        var lastError: Error?
        for _ in 0..<5 {
            do {
                let fetched = try await s3.getIndex()
                var index = fetched?.value ?? ManifestIndex.empty(updatedBy: deviceId)
                let etag = fetched?.etag
                transform(&index)
                index.updatedAt = ISO8601.now()
                index.updatedBy = deviceId
                _ = try await s3.putIndex(index, ifMatch: etag)
                return
            } catch {
                // 412 / 409 は index.json への並行更新による一時的失敗。再取得してリトライ。
                if S3ErrorClassifier.isPreconditionFailed(error)
                    || S3ErrorClassifier.isConditionalConflict(error) {
                    lastError = error
                    let nanos = UInt64.random(in: 100_000_000...500_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                    continue
                }
                throw error
            }
        }
        throw SyncError.manifestUpdateFailed(
            "index.json conditional update failed 5 times: \(String(describing: lastError))"
        )
    }
}
