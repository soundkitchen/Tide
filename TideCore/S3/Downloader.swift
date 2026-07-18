import Foundation
import GRDB
import CryptoKit

/// `Downloader` が必要とする S3 ストリーミング取得の最小シーム。
/// 本番は `TideS3Client` が適合し、テストはフェイクを差し込んで（ネットワーク無しで）再開ロジックを検証する。
/// `versionId` 指定で特定バージョンを取得する（nil = 最新版）。アップロード競合の解決（Issue #25 / A）では
/// 本体 PUT が「最新」を自分の内容に変えてしまっているため、リモート版を必ず `versionId` 指定で取得する。
public protocol RangedDownloadClient: Sendable {
    func streamObject(
        key: String,
        versionId: String?,
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
public struct Downloader: Sendable {
    public let downloadClient: any RangedDownloadClient
    public let db: LocalDatabase
    public let syncRoot: URL
    public let tmpDir: URL
    public let deviceId: String
    /// 中断・再開（サブ D）の checkpoint 永続化。
    public let transferStore: any TransferStateStoring
    /// 進捗報告（メニューバー表示用）。nil 可。
    public var progressReporter: TransferProgressReporter? = nil
    /// ダウンロード帯域制御（サブ E）。複数ファイル並行 DL で共有する。nil = 無制限。
    public var downloadLimiter: RateLimiter? = nil

    public init(
        downloadClient: any RangedDownloadClient,
        db: LocalDatabase,
        syncRoot: URL,
        tmpDir: URL,
        deviceId: String,
        transferStore: any TransferStateStoring,
        progressReporter: TransferProgressReporter? = nil,
        downloadLimiter: RateLimiter? = nil
    ) {
        self.downloadClient = downloadClient
        self.db = db
        self.syncRoot = syncRoot
        self.tmpDir = tmpDir
        self.deviceId = deviceId
        self.transferStore = transferStore
        self.progressReporter = progressReporter
        self.downloadLimiter = downloadLimiter
    }

    /// リモート 1 ファイルをローカルに反映する。
    /// - Parameters:
    ///   - versionId: 取得する S3 バージョン。nil = 最新版（通常 pull）。アップロード競合の解決では
    ///     本体 PUT が最新を自分の内容に変えているため `entry.s3VersionId` を渡して相手版を確実に取得する。
    ///   - clearQueueByPath: 完了時に同 path の upload キュー行を path 基準で削除するか。通常 pull は true
    ///     （リモート採用が pending な local upload を上書きするのは正当）。アップロード競合の解決は false
    ///     ＝行ライフサイクルを解決ヘルパが item.id 基準で所有し、処理中に届いた新 id 行を巻き込まない
    ///     （不変条件 [キュー行 id 基準] の維持・Issue #25 BUG1）。
    /// - Returns: 実際に書き込みが行われたら true、スキップなら false。
    @discardableResult
    public func download(
        relativePath: String,
        entry: ManifestFileEntry,
        versionId: String? = nil,
        clearQueueByPath: Bool = true
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
        // versionId 指定（競合解決の特定版取得）時は tmp 名にも織り込み、並行 pull（最新版）の共有 tmp と
        // 衝突させない（dl-<sha(path)>.part の取り合いで torn になる窓を塞ぐ・Issue #25 RISK4）。
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpURL = Self.resumeTmpURL(in: tmpDir, relativePath: relativePath, versionId: versionId)

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
                key: s3Key, versionId: versionId,
                rangeStart: resumeFrom > 0 ? resumeFrom : nil, limiter: downloadLimiter
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
            // 再 arm するのはこの resumable 失敗（部分 tmp 保持）と、下のローカル適用ブロック失敗のみ。
            // 破棄系（SHA/サイズ不一致・404）は決定的に再失敗するため再 arm せず、リモートのシャード
            // etag 変化による自然回復に委ねる。
            await rearmShardCache(forPath: relativePath, context: "in-session resume")
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
        if let mtimeDate = ISO8601.parse(entry.mtime) {
            try? FileManager.default.setAttributes(
                [.modificationDate: mtimeDate],
                ofItemAtPath: tmpURL.path
            )
        }

        // ローカル適用（親ディレクトリ作成 → 差し替え move）。「path の種別置換にブロックされた」失敗
        //（EEXIST/ENOTDIR/516/-16 = `isBlockedByPathTypeChange`）に限りシャードキャッシュを再 arm して
        // 次回 pull に再試行させる（Issue #52）: 伝播窓では祖先名が既存ファイルで塞がれて createDirectory
        // が決定的に失敗するが、塞いでいる旧エントリは後続 pull の削除反映/競合退避で除かれ、その後は
        // 成功する。re-arm しないと shard_state が「取得済み」のまま残り、FileRecord の無い端末（初回
        // 取得側）では DB 再合成にも乗らず、エラーの無いまま恒久的に取り残される。
        // エラークラスを絞るのは、EACCES/ENOSPC 等の非自己回復失敗まで再 arm すると「毎 pull フル再 DL →
        // 失敗 → 破棄」が pull 周期ごとに無期限リピートするため（PR #53 レビュー #4。バックオフ機構の
        // 無い pull 側では大ファイルの GET 課金・帯域が際限なく漏れる）。非ブロック系は従来どおり
        // 行/tmp を保持したまま失敗を伝播する（停滞分は起動時 prune が掃除）。
        do {
            // 親ディレクトリ作成は SHA 検証後に行う＝不一致で捨てるときに空ディレクトリの litter を残さない。
            try FileManager.default.createDirectory(
                at: fullURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // 転送中に path がディレクトリへ置換されていたら削除しない（PR #53 レビュー #8）:
            // removeItem は再帰削除なので、置換後の新ディレクトリのツリーを競合退避なしに消してしまう。
            // -16 で throw すればブロック系として再 arm され、次回 pull の reconcile が
            // unreadable → conflictThenDownload でディレクトリを退避してから取得する＝データ温存で自己回復。
            // attributesOfItem は symlink を辿らない（symlink なら .typeSymbolicLink）。
            if let type = (try? FileManager.default.attributesOfItem(atPath: fullURL.path))?[.type] as? FileAttributeType,
               type == .typeDirectory {
                throw Self.downloaderError(-16, "download target became a directory; refusing to replace")
            }

            // 既存ファイルを削除してから rename（同一 FS なので atomic）。
            // replaceItemAt は sandbox 中間ファイル (`.sb-*`) を作って FSEvents を汚すので使わない。
            if FileManager.default.fileExists(atPath: fullURL.path) {
                try FileManager.default.removeItem(at: fullURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: fullURL)
        } catch {
            // 順序は [prune 順序]（CLAUDE.md §7）と同じ「invalidate → 破棄」（PR #53 レビュー #2）。
            // 逆順だと invalidate 失敗や直後のクラッシュで「行なし + 実 etag のまま」になり、
            // 本 PR が塞いだ沈黙恒久停止が再発する。invalidate に失敗したら行/tmp を温存する
            // （行が残れば次回起動の prune が tmp 欠損/stale 枝で invalidate を引き受けて自己回復）。
            // tmp は完了サイズなので resume 対象にならず、破棄してよい（成功時のみ）。
            if Self.isBlockedByPathTypeChange(error) {
                if await rearmShardCache(forPath: relativePath, context: "local apply") {
                    await cleanupFailedDownload(tmpURL: tmpURL, path: relativePath)
                }
            }
            AppLogger.s3.error("Local apply failed for \(relativePath, privacy: .private): \(String(describing: error), privacy: .private)")
            throw error
        }

        // 再開状態をクリア（完了したので不要）+ DB 反映
        try await transferStore.clearDownload(path: relativePath)
        try await updateDBEntryAfterDownload(
            relativePath: relativePath, entry: entry, clearQueueByPath: clearQueueByPath
        )
        AppLogger.s3.info("Downloaded (bytes=\(total)): \(relativePath, privacy: .private)")
        return true
    }

    /// 既存ローカルファイルを衝突用にリネームし、その新パスを返す。
    /// rename された後のファイルは M1 ロジックでアップロードキューに乗ることが期待される。
    @discardableResult
    public func renameLocalForConflict(
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
    public func applyRemoteDeletion(relativePath: String) async throws -> Bool {
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
        // #31 / D2: O_NOFOLLOW でリンク先を読まない（上の isSymbolicLink ガード後の TOCTOU 窓も塞ぐ＝
        // 差し替えられても nil → .unreadable → keepLocalRemoteDeleted で温存）。
        let localState: LocalState = (try? HashCalculator.sha256NoFollow(of: fullURL)).map(LocalState.present) ?? .unreadable
        let decision = ThreeWayMerge.decide(base: dbRec?.sha256, local: localState, remote: nil)

        // 明示列挙（default を使わない）: remote = nil 固定 + 上の存在ガード（line 349 通過で
        // localState は .present / .unreadable のいずれか＝決して .absent にならない）により、
        // ここに来る decide() の結果は .deleteLocal / .keepLocalRemoteDeleted の 2 つだけ。
        // 特に .noop（decide が (.absent, nil) からのみ返す）が排除されるのは remote = nil ではなく
        // この存在ガードによる。残りは到達不能で、来たら decide() のロジックバグとして
        // assertionFailure で検出しつつ安全側（削除しない）に倒す。pull 側 reconcileRemoteEntry の
        // 7 case 明示列挙 + assertionFailure と対称の防御（PR #70 レビュー観察 1・再レビューの精度補足）。
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
        case .keepLocalRemoteDeleted:
            // ローカル編集/未追跡 or ハッシュ不能 → 温存し warning。
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
        case .download, .localMatchesRemote, .conflictThenDownload, .awaitLocalDeletePropagation, .noop:
            // remote = nil + 存在ガード（.absent 排除）により到達不能。安全側（削除しない）に倒す。
            assertionFailure("unreachable: remote is nil and local exists in applyRemoteDeletion")
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

    /// 当該 path のシャードキャッシュを sentinel 化（空 etag）して次回 pull に再取得させる（再 arm）。
    /// 失敗は無音にしない（PR #9 レビュー ⑤）。呼び出し側は返値で [prune 順序]（invalidate 成功後に
    /// のみ行/tmp を破棄）を守る。`cleanupFailedDownload` へは統合しない — 他の破棄系呼び出し元
    /// （SHA/サイズ不一致・404）は決定的に再失敗するため再 arm してはならない。
    @discardableResult
    private func rearmShardCache(forPath path: String, context: StaticString) async -> Bool {
        do {
            try await db.invalidateShardCache(forPath: path)
            return true
        } catch {
            AppLogger.s3.error("Re-arm (\(context, privacy: .public)) failed for \(path, privacy: .private): \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// ローカル適用失敗のうち「path（または祖先）の種別置換にブロックされた」ものか判定する
    /// （Issue #52 の伝播窓・PR #53 レビュー #4）。真になるのは:
    /// - POSIX `EEXIST`(17) / `ENOTDIR`(20)（祖先がファイルで塞がれた createDirectory/move）
    /// - Cocoa `NSFileWriteFileExistsError`(516)（同上の Cocoa 包装）
    /// - 自ドメイン -16（転送中に DL 先がディレクトリ化・上記 throw）
    /// これらは後続 pull の削除反映/競合退避でブロッカーが除かれ再試行が成功する見込みがある。
    /// それ以外（EACCES/ENOSPC 等）を再 arm すると毎 pull のフル再 DL が無期限化するため除外する。
    /// `SyncError.ioError` は underlying を取り出し、NSError の underlying 連鎖を辿って判定する。
    public static func isBlockedByPathTypeChange(_ error: Error) -> Bool {
        var cursor: NSError?
        if case SyncError.ioError(let underlying) = error {
            cursor = underlying as NSError
        } else {
            cursor = error as NSError
        }
        while let cur = cursor {
            if cur.domain == NSPOSIXErrorDomain, cur.code == Int(EEXIST) || cur.code == Int(ENOTDIR) {
                return true
            }
            if cur.domain == NSCocoaErrorDomain, cur.code == NSFileWriteFileExistsError {
                return true
            }
            if cur.domain == "Tide.Downloader", cur.code == -16 {
                return true
            }
            cursor = cur.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// 相対パスから決定的な tmp ファイル名を導く（再開で同じ tmp を再発見できるように）。
    /// 内容（etag）が変わった場合は `transferStore.expectedEtag` の照合で破棄するので、名前は path のみで決める。
    /// `versionId` 指定（競合解決の特定版取得）時のみ名前に織り込み、最新版 pull の共有 tmp と区別する
    /// （並行取得で同一 tmp を取り合って torn になる窓を塞ぐ・Issue #25 RISK4）。nil なら従来どおり path のみ。
    public static func resumeTmpURL(in tmpDir: URL, relativePath: String, versionId: String? = nil) -> URL {
        let seed = versionId.map { "\(relativePath)\u{0}\($0)" } ?? relativePath
        let h = HashCalculator.hex(SHA256.hash(data: Data(seed.utf8)))
        return tmpDir.appendingPathComponent("dl-\(h).part")
    }

    /// tmp を **symlink 非追従**で書込用に開く。`append=false`（fresh）は `O_CREAT|O_EXCL|O_NOFOLLOW`
    /// で新規作成（既存 or symlink なら失敗＝追従しない）、`append=true`（resume）は `O_WRONLY|O_NOFOLLOW`
    /// で開いて末尾へ seek。アップロード側の `NoFollowFileReader` と対称に、書込側の symlink 追従窓を閉じる（#3）。
    public static func openTmpForWriting(at url: URL, append: Bool) throws -> FileHandle {
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

    public static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// 既存の部分ファイルを読み切って hasher に前置きする（再開時に全体 SHA を復元するため）。
    public static func hashPrefix(of url: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }

    private func currentLocalSha(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // #31 / D2: O_NOFOLLOW でリンク先を読まない。最終コンポーネントが symlink なら
        // FileOpenError.isSymbolicLink を投げて呼び元へ伝播する（旧 sha256(of:) は symlink を追従して
        // リンク先を hash していたので、これは新たな throw ケース。ただし download() 入口の
        // isSymbolicLink ガードで通常は到達せず、発火は差し替え TOCTOU 窓のみ＝書込中断で安全側）。
        return try HashCalculator.sha256NoFollow(of: url)
    }

    private func updateDBEntryAfterDownload(
        relativePath: String,
        entry: ManifestFileEntry,
        clearQueueByPath: Bool = true
    ) async throws {
        let now = Date().timeIntervalSince1970
        let mtime = ISO8601.parse(entry.mtime)?.timeIntervalSince1970 ?? now
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
            // 既にローカル発で upload キューに入っていたら不要になる（通常 pull）。
            // ただしアップロード競合の解決経路（clearQueueByPath=false）では path 基準で消さない:
            // 処理中に届いた同 path の新 id 行を巻き込まないため（行ライフサイクルは解決ヘルパが
            // item.id 基準で所有・不変条件 [キュー行 id 基準]・Issue #25 BUG1）。
            if clearQueueByPath {
                try UploadQueueRecord
                    .filter(Column("path") == relativePath)
                    .deleteAll(db)
            }
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
    public func markSynced(
        relativePath: String,
        entry: ManifestFileEntry,
        localMtime: Double?
    ) async throws {
        let now = Date().timeIntervalSince1970
        let mtime = localMtime ?? ISO8601.parse(entry.mtime)?.timeIntervalSince1970 ?? now
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

