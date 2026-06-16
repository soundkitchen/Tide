import Foundation
import GRDB
import CryptoKit

/// `Downloader` が必要とする S3 ストリーミング取得の最小シーム。
/// 本番は `TideS3Client` が適合し、テストはフェイクを差し込んで（ネットワーク無しで）再開ロジックを検証する。
protocol RangedDownloadClient: Sendable {
    func streamObject(
        key: String,
        rangeStart: Int64?,
        limiter: RateLimiter?,
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
            return Downloader.downloaderError(-23, "downloaded body exceeds expected size for key \(key)")
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
    /// ダウンロード帯域制御（サブ E）。複数ファイル並行 DL で共有する。nil = 無制限。
    var downloadLimiter: RateLimiter? = nil

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
            throw Self.downloaderError(-13, "target is a symbolic link; refusing to write")
        }

        let s3Key = "files/\(relativePath)"

        // 既に同じ SHA がローカルにあるならスキップ。
        // mtime は sha 計算の「前」に stat する: ハッシュ中に書き換わっても「旧 mtime + 旧 sha」の
        // 組で残り、次回スキャンの mtime 差から再検出される（安全方向）。後 stat だと
        // 「新 mtime + 旧 sha」の組になり、変更の取りこぼしが恒久化し得る。
        let localStatMtime = Self.fileMtime(at: fullURL)
        if let localSha = try currentLocalSha(at: fullURL), localSha == entry.sha256 {
            try await markSynced(
                relativePath: relativePath, entry: entry, localMtime: localStatMtime
            )
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
           !entry.etag.isEmpty,                          // 空 etag だと == 照合が no-op になるので resume しない（#4）
           persisted.tmpPath == tmpURL.path,
           persisted.expectedEtag == entry.etag,
           !PathValidator.isSymbolicLink(at: tmpURL),   // tmp が symlink に差し替わっていたら resume せず破棄
           let existingSize = Self.fileSize(at: tmpURL),
           existingSize > 0, existingSize < entry.size {
            resumeFrom = existingSize
            try Self.hashPrefix(of: tmpURL, into: &hasher)
        } else {
            // 行が無い / etag 不一致(or 空) / tmp 無し or サイズ不整合 → フル取得を仕切り直す。
            // #3: createFile は symlink を追従するため使わず、下の openTmpForWriting(O_CREAT|O_EXCL|O_NOFOLLOW)
            //     で新規作成する。ここでは古い tmp（symlink 含む）を消すだけ。
            try? FileManager.default.removeItem(at: tmpURL)
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
        // #3: tmp 書込先の symlink 追従を防ぐ。fresh は O_CREAT|O_EXCL|O_NOFOLLOW で新規作成、
        //     resume は O_WRONLY|O_NOFOLLOW で開いて末尾へ seek（追従窓を構造的に閉じる）。
        let handle = try Self.openTmpForWriting(at: tmpURL, append: resumeFrom > 0)
        let streamResult: TideS3Client.StreamObjectResult?
        do {
            streamResult = try await downloadClient.streamObject(
                key: s3Key, rangeStart: resumeFrom > 0 ? resumeFrom : nil, limiter: downloadLimiter
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
            await cleanupFailedDownload(tmpURL: tmpURL, path: relativePath)
            AppLogger.s3.error("Download exceeded expected size: \(relativePath, privacy: .private)")
            throw abort.asSyncError(key: s3Key)
        } catch {
            // ネットワーク等の失敗 → 部分 tmp と行を保持し、次回 Range 再開に委ねる（abort/clear しない）。
            // 「等」にはローカル I/O 失敗（handle.write のディスクフル等）も含む: 決定的な破棄系とは違い
            // Range 再開で再試行コストが小さく、空き容量回復で自己回復するため、同様に保持 + 再 arm する。
            // #1: 進捗を記録して bytes_done を最新化 + updated_at を前進させる
            //     （起動時 prune の stale 判定が「実活動」を反映し、進捗のある tmp を 7 日で誤って消さない）。
            try? handle.close()
            try? await transferStore.recordDownloadProgress(path: relativePath, bytesDone: total)
            // PR #9 レビュー ②: ManifestReader は fetch 時点（DL 完了前）で shard_state を「取得済み」記録
            // するため、ここで sentinel 化しないと同一セッション中の poll/wake/network-up pull が当該
            // シャードをキャッシュ済み扱いし、再開経路（reconcile → Range 再開）に到達しない。
            // 再 arm するのはこの resumable 失敗（部分 tmp 保持）のみ。破棄系（SHA/サイズ不一致・404）は
            // 決定的に再失敗するため再 arm せず、リモートのシャード etag 変化による自然回復に委ねる。
            do {
                try await db.invalidateShardCache(forPath: relativePath)
            } catch {
                // 失敗すると「シャード変化 or 再起動まで取り残し」が再発するので無音にしない（PR #9 レビュー ⑤）。
                AppLogger.s3.error("Re-arm in-session download failed for \(relativePath, privacy: .private): \(String(describing: error), privacy: .private)")
            }
            throw error
        }

        guard streamResult != nil else {
            // 404: 行と部分 tmp を掃除
            await cleanupFailedDownload(tmpURL: tmpURL, path: relativePath)
            AppLogger.s3.error("Download object not found on S3: \(relativePath, privacy: .private)")
            throw Self.downloaderError(-10, "object not found on S3")
        }

        // 実ファイルサイズ検証（防御的・並行追記対策）:
        // ストリームの `total` は「この呼び出しが論理的に処理したバイト数」で、共有 tmp
        // （dl-<sha(path)>.part）へ別経路が並行追記しても捕捉できない。commit 前に **実 tmp サイズ**を
        // 期待 `entry.size` と必ず突合し、不一致なら破棄して仕切り直す。これを欠くと、過大化した tmp が
        // SHA ゲート（論理ハッシュ）をすり抜けて commit され、監視経由で再アップロードされてリモートの
        // マニフェストまで汚染する事故が起きる。pull の単一ゲート化（SyncEngine 側）と二段で防ぐ。
        let actualSize = Self.fileSize(at: tmpURL) ?? -1
        if actualSize != entry.size {
            await cleanupFailedDownload(tmpURL: tmpURL, path: relativePath)
            AppLogger.s3.error("Downloaded size mismatch (\(actualSize) != \(entry.size)): \(relativePath, privacy: .private)")
            throw Self.downloaderError(-15, "downloaded file size mismatch")
        }

        // SHA 検証（不一致なら tmp を捨てて行をクリアし失敗＝壊れた内容を再開し続けない）
        let sha = HashCalculator.hex(hasher.finalize())
        if sha != entry.sha256 {
            await cleanupFailedDownload(tmpURL: tmpURL, path: relativePath)
            AppLogger.s3.error("SHA mismatch downloading \(relativePath, privacy: .private)")
            throw Self.downloaderError(-11, "SHA-256 mismatch")
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
                throw Self.downloaderError(-12, "could not find non-conflicting rename for \(relativePath)")
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
                eventType: SyncLogEventType.conflict.rawValue,
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
                    eventType: SyncLogEventType.delete.rawValue,
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
                    eventType: SyncLogEventType.conflict.rawValue,
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

    /// `SyncError.ioError` を `Tide.Downloader` ドメインで生成する共通ファクトリ（NSError 生成の定型を集約）。
    fileprivate static func downloaderError(_ code: Int, _ message: String) -> SyncError {
        SyncError.ioError(underlying: NSError(
            domain: "Tide.Downloader", code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    /// DL を破棄して仕切り直す失敗経路の後始末（部分 tmp 削除 + 再開行クリア）。
    /// 後続の log / throw は呼び出し側に残す。resumable 失敗（部分 tmp を保持して Range 再開）には使わない。
    private func cleanupFailedDownload(tmpURL: URL, path: String) async {
        try? FileManager.default.removeItem(at: tmpURL)
        try? await transferStore.clearDownload(path: path)
    }

    /// 相対パスから決定的な tmp ファイル名を導く（再開で同じ tmp を再発見できるように）。
    /// 内容（etag）が変わった場合は `transferStore.expectedEtag` の照合で破棄するので、名前は path のみで決める。
    static func resumeTmpURL(in tmpDir: URL, relativePath: String) -> URL {
        let h = HashCalculator.hex(SHA256.hash(data: Data(relativePath.utf8)))
        return tmpDir.appendingPathComponent("dl-\(h).part")
    }

    /// tmp を **symlink 非追従**で書込用に開く。`append=false`（fresh）は `O_CREAT|O_EXCL|O_NOFOLLOW`
    /// で新規作成（既存 or symlink なら失敗＝追従しない）、`append=true`（resume）は `O_WRONLY|O_NOFOLLOW`
    /// で開いて末尾へ seek。アップロード側の `NoFollowFileReader` と対称に、書込側の symlink 追従窓を閉じる（#3）。
    static func openTmpForWriting(at url: URL, append: Bool) throws -> FileHandle {
        let flags: Int32 = append
            ? (O_WRONLY | O_NOFOLLOW)
            : (O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW)
        let fd = url.path.withCString { open($0, flags, 0o600) }
        if fd < 0 {
            let err = errno
            throw Self.downloaderError(-14, "failed to open tmp for writing (errno \(err))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if append { try handle.seekToEnd() }
        return handle
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
                eventType: SyncLogEventType.download.rawValue,
                path: relativePath,
                message: "Downloaded \(entry.size) bytes",
                details: nil
            )
            try log.insert(db)
        }
    }

    /// scan の mtime 取得（`.contentModificationDateKey`）と同じ API 系で stat する。
    private static func fileMtime(at url: URL) -> Double? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
    }

    /// 内容一致時に、実書込なし（FS を触らず）で DB メタデータのみ最新化する。
    /// 呼び元は 2 つ: `download()` の早期 return（ローカル内容がリモートと一致）と、reconcile の
    /// `.localMatchesRemote`（再 hash を避けるため `download()` に畳まず直接呼ぶ・pull コスト削減 M4）。
    ///
    /// mtime は**ローカル stat 実値**を記録する（不変条件: 「DB.mtime = 最後に同期した時点の
    /// ローカル stat mtime」）。マニフェスト mtime は ISO8601 秒精度（fractional なし）に
    /// 切り捨てられており、これで上書きすると次回フルスキャンの `< 0.001` 比較が必ず外れ、
    /// 無変更ファイルが毎起動再アップロードされる自己持続サイクルになる（pull は未変化シャードでも
    /// 全 entry をここに通すため、毎 pull で汚染されていた）。stat 失敗時のみマニフェスト値へ
    /// フォールバック（従来挙動）。
    func markSynced(
        relativePath: String,
        entry: ManifestFileEntry,
        localMtime: Double?
    ) async throws {
        let now = Date().timeIntervalSince1970
        let mtime = localMtime ?? parseISO8601(entry.mtime)?.timeIntervalSince1970 ?? now
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

