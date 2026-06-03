import Foundation
import GRDB

/// 単一ファイルのダウンロードと、それに伴うローカル書き込み・DB 更新をまとめた処理。
struct Downloader {
    let s3: TideS3Client
    let db: LocalDatabase
    let syncRoot: URL
    let tmpDir: URL
    let deviceId: String

    /// リモート 1 ファイルをローカルに反映する。
    /// - Returns: 実際に書き込みが行われたら true、スキップなら false。
    @discardableResult
    func download(
        relativePath: String,
        entry: ManifestFileEntry
    ) async throws -> Bool {
        // C1/C2/F2: 入口でリモート由来パスを検証 + sync root エスケープ防止（祖先 symlink 経由の脱出も含む）
        let fullURL = try PathValidator.resolveForWrite(relativePath: relativePath, syncRoot: syncRoot)
        // 既存パスがシンボリックリンクなら拒否（リンク先実体を書き換えない）
        if PathValidator.isSymbolicLink(at: fullURL) {
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.Downloader",
                code: -13,
                userInfo: [NSLocalizedDescriptionKey: "target is a symbolic link; refusing to write"]
            ))
        }

        let s3Key = "files/\(relativePath)"

        // 既に同じ SHA がローカルにあるならスキップ
        if let localSha = try currentLocalSha(at: fullURL), localSha == entry.sha256 {
            try await updateDBEntryWithoutWrite(relativePath: relativePath, entry: entry)
            return false
        }

        // 一時ファイルは SyncEngine 起動時に決めた tmpDir に置く
        // （同一ボリュームが保証されるので、後段の moveItem が atomic な rename になる）
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpURL = tmpDir.appendingPathComponent(UUID().uuidString)

        // S3 からチャンク・ストリーミングで tmp へ取得し、SHA-256 を逐次計算する。メモリはチャンクで有界。
        // M7: マニフェストの真実サイズ entry.size を maxBytes に渡し、サーバ申告 contentLength と
        // 受信累積長の両方で弾く（巨大本文による同期ボリュームのディスク枯渇 DoS を防ぐ＝M4 の cap を復元経路でも維持）。
        guard let result = try await s3.downloadToFile(key: s3Key, into: tmpURL, maxBytes: entry.size) else {
            AppLogger.s3.error("Download object not found on S3: \(relativePath, privacy: .private)")
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.Downloader",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "object not found on S3"]
            ))
        }

        // SHA 検証（不一致なら書きかけ tmp を捨てて失敗）
        if result.sha256 != entry.sha256 {
            try? FileManager.default.removeItem(at: tmpURL)
            AppLogger.s3.error("SHA mismatch downloading \(relativePath, privacy: .private)")
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.Downloader",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "SHA-256 mismatch"]
            ))
        }

        // mtime 復元（rename で保たれる）
        if let mtimeDate = parseISO8601(entry.mtime) {
            try? FileManager.default.setAttributes(
                [.modificationDate: mtimeDate],
                ofItemAtPath: tmpURL.path
            )
        }

        // 親ディレクトリ作成（SHA 検証後に行う＝不一致で捨てるときに空ディレクトリの litter を残さない）
        try FileManager.default.createDirectory(
            at: fullURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 既存ファイルを削除してから rename（同一 FS なので atomic）。
        // replaceItemAt は sandbox 中間ファイル (`.sb-*`) を作って FSEvents を汚すので使わない。
        if FileManager.default.fileExists(atPath: fullURL.path) {
            try FileManager.default.removeItem(at: fullURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: fullURL)

        // DB 反映
        try await updateDBEntryAfterDownload(relativePath: relativePath, entry: entry)
        AppLogger.s3.info("Downloaded (bytes=\(result.bytes)): \(relativePath, privacy: .private)")
        return true
    }

    /// 既存ローカルファイルを衝突用にリネームし、その新パスを返す。
    /// rename された後のファイルは M1 ロジックでアップロードキューに乗ることが期待される。
    @discardableResult
    func renameLocalForConflict(
        relativePath: String
    ) throws -> String {
        try PathValidator.validateRelativePath(relativePath)
        let now = Date()
        var newRelative = ConflictNamer.localCopyRelativePath(for: relativePath, at: now)
        try PathValidator.validateRelativePath(newRelative)

        // 同名がもしも既にあったらサフィックスでさらに分ける
        var tries = 0
        while FileManager.default.fileExists(atPath: syncRoot.appendingPathComponent(newRelative).path) {
            tries += 1
            if tries > 10 {
                throw SyncError.ioError(underlying: NSError(
                    domain: "Tide.Downloader",
                    code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "could not find non-conflicting rename for \(relativePath)"]
                ))
            }
            newRelative = ConflictNamer.localCopyRelativePath(for: relativePath, at: now.addingTimeInterval(Double(tries)))
        }

        // F2: 祖先 symlink 経由でルート外を移動元/移動先にしない
        let from = try PathValidator.resolveForWrite(relativePath: relativePath, syncRoot: syncRoot)
        let to = try PathValidator.resolveForWrite(relativePath: newRelative, syncRoot: syncRoot)
        try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: from, to: to)
        AppLogger.sync.info("Conflict rename: \(relativePath, privacy: .private) → \(newRelative, privacy: .private)")

        // DB からも該当エントリ削除（次のフルスキャンで新パス側がアップロードキューに入る）
        try db.pool.write { db in
            try FileRecord.deleteOne(db, key: relativePath)
            var log = SyncLogRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                eventType: "conflict",
                path: relativePath,
                message: "Renamed local copy → \(newRelative)",
                details: nil
            )
            try log.insert(db)
        }

        return newRelative
    }

    /// リモート削除をローカルに反映（SHA が DB 記録と一致＝ユーザが触っていない時のみ削除）。
    /// - Returns: 削除を実行したら true、温存したら false。
    @discardableResult
    func applyRemoteDeletion(relativePath: String) async throws -> Bool {
        // F2: 祖先 symlink 経由でルート外のファイルを削除しない
        let fullURL = try PathValidator.resolveForWrite(relativePath: relativePath, syncRoot: syncRoot)
        // シンボリックリンクは削除対象外（リンク先実体を消さない）
        if PathValidator.isSymbolicLink(at: fullURL) {
            AppLogger.sync.info("Refusing to remove a symbolic link: \(relativePath, privacy: .private)")
            return false
        }

        // 既にローカルにない
        guard FileManager.default.fileExists(atPath: fullURL.path) else {
            try await db.pool.write { db in
                try FileRecord.deleteOne(db, key: relativePath)
            }
            return false
        }

        let dbRec = try await db.pool.read { db in
            try FileRecord.fetchOne(db, key: relativePath)
        }
        let currentSha: String? = try? HashCalculator.sha256(of: fullURL)

        // 競合解決は ThreeWayMerge に一本化（remote = nil の削除側）。
        // ファイルは存在するがハッシュ不能のときは「未編集と確認できない」ので保守的に温存する。
        let decision: MergeDecision = currentSha.map {
            ThreeWayMerge.decide(base: dbRec?.sha256, local: $0, remote: nil)
        } ?? .keepLocalRemoteDeleted

        switch decision {
        case .deleteLocal:
            try FileManager.default.removeItem(at: fullURL)
            try await db.pool.write { db in
                try FileRecord.deleteOne(db, key: relativePath)
                var log = SyncLogRecord(
                    id: nil,
                    timestamp: Date().timeIntervalSince1970,
                    eventType: "delete",
                    path: relativePath,
                    message: "Removed locally (remote deletion)",
                    details: nil
                )
                try log.insert(db)
            }
            AppLogger.sync.info("Removed locally (remote deletion): \(relativePath, privacy: .private)")
            return true
        default:
            // .keepLocalRemoteDeleted（ローカル編集/未追跡 or ハッシュ不能）→ 温存し warning。
            try await db.pool.write { db in
                var log = SyncLogRecord(
                    id: nil,
                    timestamp: Date().timeIntervalSince1970,
                    eventType: "conflict",
                    path: relativePath,
                    message: "Remote deleted but local was modified; keeping local copy",
                    details: nil
                )
                try log.insert(db)
            }
            AppLogger.sync.info("Skip remote-deletion (local modified): \(relativePath, privacy: .private)")
            return false
        }
    }

    // MARK: - helpers

    private func currentLocalSha(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try HashCalculator.sha256(of: url)
    }

    private func parseISO8601(_ s: String) -> Date? {
        try? Date(s, strategy: .iso8601)
    }

    private func updateDBEntryAfterDownload(
        relativePath: String,
        entry: ManifestFileEntry
    ) async throws {
        let now = Date().timeIntervalSince1970
        let mtime = parseISO8601(entry.mtime)?.timeIntervalSince1970 ?? now
        try await db.pool.write { db in
            var rec = FileRecord(
                path: relativePath,
                size: entry.size,
                mtime: mtime,
                sha256: entry.sha256,
                s3VersionId: entry.s3VersionId,
                s3Etag: entry.etag,
                lastSyncedAt: now,
                updatedAt: now
            )
            try rec.save(db)
            // 既にローカル発で upload キューに入っていたら不要になる
            try UploadQueueRecord
                .filter(Column("path") == relativePath)
                .deleteAll(db)
            var log = SyncLogRecord(
                id: nil,
                timestamp: now,
                eventType: "download",
                path: relativePath,
                message: "Downloaded \(entry.size) bytes",
                details: nil
            )
            try log.insert(db)
        }
    }

    private func updateDBEntryWithoutWrite(
        relativePath: String,
        entry: ManifestFileEntry
    ) async throws {
        let now = Date().timeIntervalSince1970
        let mtime = parseISO8601(entry.mtime)?.timeIntervalSince1970 ?? now
        try await db.pool.write { db in
            var rec = FileRecord(
                path: relativePath,
                size: entry.size,
                mtime: mtime,
                sha256: entry.sha256,
                s3VersionId: entry.s3VersionId,
                s3Etag: entry.etag,
                lastSyncedAt: now,
                updatedAt: now
            )
            try rec.save(db)
        }
    }
}

