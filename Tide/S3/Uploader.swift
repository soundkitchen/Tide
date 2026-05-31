import Foundation
import GRDB

/// 単一ファイルのアップロード / 削除と、それに伴うマニフェスト・DB 更新をまとめた処理。
struct Uploader {
    static let maxSizeM1: Int64 = 100 * 1024 * 1024  // 100 MiB

    let s3: TideS3Client
    let db: LocalDatabase
    let syncRoot: URL
    let deviceId: String

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

        // 1. attribute / hash
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: fullURL.path)
        } catch CocoaError.fileReadNoSuchFile {
            // 読み込みタイミングで削除された → delete として再処理
            try await convertQueueItemToDelete(item)
            return
        }

        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtimeDate = (attrs[.modificationDate] as? Date) ?? Date()
        let mtime = mtimeDate.timeIntervalSince1970

        if size > Self.maxSizeM1 {
            try await db.pool.write { db in
                try UploadQueueRecord
                    .filter(Column("path") == path)
                    .deleteAll(db)
                var log = SyncLogRecord(
                    id: nil,
                    timestamp: Date().timeIntervalSince1970,
                    eventType: "error",
                    path: path,
                    message: "File too large for M1 (>100MB). Skipped. // TODO(M3): multipart upload",
                    details: "size=\(size)"
                )
                try log.insert(db)
            }
            AppLogger.sync.error("Skipped large file (\(size) bytes): \(path, privacy: .private)")
            return
        }

        let sha256: String
        do {
            sha256 = try HashCalculator.sha256(of: fullURL)
        } catch CocoaError.fileReadNoSuchFile {
            try await convertQueueItemToDelete(item)
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fullURL)
        } catch CocoaError.fileReadNoSuchFile {
            try await convertQueueItemToDelete(item)
            return
        }

        // 2. S3 upload
        let metadata: [String: String] = [
            "sha256": sha256,
            "mtime": ISO8601.format(mtimeDate),
            "device": deviceId,
            "size": String(size)
        ]
        let s3Key = "files/\(path)"
        let result = try await s3.putObject(
            key: s3Key,
            data: data,
            contentType: "application/octet-stream",
            metadata: metadata
        )
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
            try UploadQueueRecord
                .filter(Column("path") == path)
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
            try UploadQueueRecord
                .filter(Column("path") == path)
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
            var updated = item
            updated.operation = "delete"
            try updated.update(db)
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
