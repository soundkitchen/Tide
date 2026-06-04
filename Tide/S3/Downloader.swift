import Foundation
import GRDB
import CryptoKit

/// `Downloader` が必要とする S3 ストリーミング取得の最小シーム。
/// 本番は `TideS3Client` が適合し、テストはフェイクを差し込んで（ネットワーク無しで）再開ロジックを検証する。
protocol RangedDownloadClient: Sendable {
    func streamObject(
        key: String,
        rangeStart: Int64?,
        sink: (Data) throws -> Void
    ) async throws -> TideS3Client.StreamObjectResult?
}

extension TideS3Client: RangedDownloadClient {}

/// サイズ上限超過など「破棄して仕切り直すべき」失敗を、ネットワーク失敗（部分を保持して再開）と区別する。
private enum DownloadAbort: Error {
    case tooLarge

    func asSyncError(key: String) -> SyncError {
        switch self {
        case .tooLarge:
            return SyncError.ioError(underlying: NSError(
                domain: "Tide.Downloader", code: -23,
                userInfo: [NSLocalizedDescriptionKey: "downloaded body exceeds expected size for key \(key)"]
            ))
        }
    }
}

/// 単一ファイルのダウンロードと、それに伴うローカル書き込み・DB 更新をまとめた処理。
struct Downloader {
    let downloadClient: any RangedDownloadClient
    let db: LocalDatabase
    let syncRoot: URL
    let tmpDir: URL
    let deviceId: String
    /// 中断・再開（サブ D）の checkpoint 永続化。
    let transferStore: any TransferStateStoring
    /// 進捗報告（メニューバー表示用）。nil 可。
    var progressReporter: TransferProgressReporter? = nil

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
        // （同一ボリュームが保証されるので、後段の moveItem が atomic な rename になる）。
        // 再開できるよう、相対パスから決定的な tmp 名を導く（UUID ではない）。
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpURL = Self.resumeTmpURL(in: tmpDir, relativePath: relativePath)

        // 再開判定: 永続行が現エントリ（etag）と一致し、tmp が部分的に存在すれば bytes_done から再開。
        // 既送プレフィクスは読み直して hash に前置きし、全体 SHA を復元する（ネットワークは未取得分だけ）。
        var resumeFrom: Int64 = 0
        var hasher = SHA256()
        let persisted = try await transferStore.loadDownload(path: relativePath)
        if let persisted,
           persisted.tmpPath == tmpURL.path,
           persisted.expectedEtag == entry.etag,
           let existingSize = Self.fileSize(at: tmpURL),
           existingSize > 0, existingSize < entry.size {
            resumeFrom = existingSize
            try Self.hashPrefix(of: tmpURL, into: &hasher)
        } else {
            // 行が無い / etag 不一致 / tmp 無し or サイズ不整合 → フル取得を仕切り直す。
            try? FileManager.default.removeItem(at: tmpURL)
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            try await transferStore.beginDownload(
                path: relativePath, tmpPath: tmpURL.path, expectedEtag: entry.etag
            )
        }

        // 進捗報告（begin → ストリーム中に coalesce して update → 関数脱出で end）。
        let reporter = progressReporter
        reporter?(.begin(path: relativePath, direction: .download, totalBytes: entry.size))
        defer { reporter?(.end(path: relativePath, direction: .download)) }
        if resumeFrom > 0 {
            reporter?(.update(path: relativePath, direction: .download, transferredBytes: resumeFrom))
        }

        // S3 からチャンク・ストリーミングで tmp へ（resume なら末尾へ追記）取得し、SHA-256 を逐次更新する。
        // M7: マニフェストの真実サイズ entry.size を上限に、累積長で弾く（巨大本文による同期ボリュームの
        // ディスク枯渇 DoS を防ぐ＝M4 の cap を復元経路でも維持）。超過は tooLarge ＝破棄して仕切り直す。
        let maxBytes = entry.size
        var total: Int64 = resumeFrom
        var lastReported: Int64 = resumeFrom
        let handle = try FileHandle(forWritingTo: tmpURL)
        let streamResult: TideS3Client.StreamObjectResult?
        do {
            if resumeFrom > 0 { try handle.seekToEnd() }
            streamResult = try await downloadClient.streamObject(
                key: s3Key, rangeStart: resumeFrom > 0 ? resumeFrom : nil
            ) { chunk in
                total += Int64(chunk.count)
                if total > maxBytes { throw DownloadAbort.tooLarge }
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
                // 進捗は ~4MiB ごとに coalesce して報告（MainActor へのホップを抑える）。
                if total - lastReported >= 4 * 1024 * 1024 {
                    lastReported = total
                    reporter?(.update(path: relativePath, direction: .download, transferredBytes: total))
                }
            }
            try handle.synchronize()
            try handle.close()
        } catch let abort as DownloadAbort {
            // サイズ上限超過（マニフェストとリモートのサイズ食い違い）→ 破棄して仕切り直し。
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
            try? await transferStore.clearDownload(path: relativePath)
            AppLogger.s3.error("Download exceeded expected size: \(relativePath, privacy: .private)")
            throw abort.asSyncError(key: s3Key)
        } catch {
            // ネットワーク等の失敗 → 部分 tmp と行を保持し、次回 Range 再開に委ねる（abort/clear しない）。
            try? handle.close()
            throw error
        }

        guard streamResult != nil else {
            // 404: 行と部分 tmp を掃除
            try? FileManager.default.removeItem(at: tmpURL)
            try? await transferStore.clearDownload(path: relativePath)
            AppLogger.s3.error("Download object not found on S3: \(relativePath, privacy: .private)")
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.Downloader",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "object not found on S3"]
            ))
        }

        // SHA 検証（不一致なら tmp を捨てて行をクリアし失敗＝壊れた内容を再開し続けない）
        let sha = HashCalculator.hex(hasher.finalize())
        if sha != entry.sha256 {
            try? FileManager.default.removeItem(at: tmpURL)
            try? await transferStore.clearDownload(path: relativePath)
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

        // 再開状態をクリア（完了したので不要）+ DB 反映
        try await transferStore.clearDownload(path: relativePath)
        try await updateDBEntryAfterDownload(relativePath: relativePath, entry: entry)
        AppLogger.s3.info("Downloaded (bytes=\(total)): \(relativePath, privacy: .private)")
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
        // ここに来た時点でファイルは必ず存在（上の guard）。SHA 取得済み or unreadable のいずれか。
        // 競合解決は ThreeWayMerge に一本化（remote = nil の削除側）。unreadable は decide() 側で温存に倒れる。
        let localState: LocalState = (try? HashCalculator.sha256(of: fullURL)).map(LocalState.present) ?? .unreadable
        let decision = ThreeWayMerge.decide(base: dbRec?.sha256, local: localState, remote: nil)

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

    /// 相対パスから決定的な tmp ファイル名を導く（再開で同じ tmp を再発見できるように）。
    /// 内容（etag）が変わった場合は `transferStore.expectedEtag` の照合で破棄するので、名前は path のみで決める。
    static func resumeTmpURL(in tmpDir: URL, relativePath: String) -> URL {
        let h = HashCalculator.hex(SHA256.hash(data: Data(relativePath.utf8)))
        return tmpDir.appendingPathComponent("dl-\(h).part")
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// 既存の部分ファイルを読み切って hasher に前置きする（再開時に全体 SHA を復元するため）。
    static func hashPrefix(of url: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }

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

