import Foundation
import GRDB

/// 単一ファイルのアップロード / 削除と、それに伴うマニフェスト・DB 更新をまとめた処理。
public struct Uploader: Sendable {
    public let s3: TideS3Client
    public let db: LocalDatabase
    public let syncRoot: URL
    public let deviceId: String
    /// 1 ファイルあたりのアップロード上限を都度参照する（Settings 変更を次の処理で反映）。
    public let config: ConfigStore
    /// 中断・再開（サブ D）の checkpoint 永続化。マルチパート経路でのみ使う。
    public let transferStore: any TransferStateStoring
    /// 進捗報告（メニューバー表示用）。マルチパート経路でのみ発行する。nil 可。
    public var progressReporter: TransferProgressReporter? = nil
    /// アップロード帯域制御（サブ E）。複数ファイル並行 UL で共有する。nil = 無制限。
    public var uploadLimiter: RateLimiter? = nil
    /// マニフェスト書込の唯一のチョークポイント。init で 1 個だけ構築して upload/delete が共用する
    /// （PR #56 レビュー ④: 構築の重複をなくし、hook＝FP signal の配線点をアプリ側 1 箇所に固定）。
    public let manifestUpdater: ManifestUpdater

    public init(
        s3: TideS3Client,
        db: LocalDatabase,
        syncRoot: URL,
        deviceId: String,
        config: ConfigStore,
        transferStore: any TransferStateStoring,
        progressReporter: TransferProgressReporter? = nil,
        uploadLimiter: RateLimiter? = nil,
        // 既定値なし（PR #56 再レビュー (2)）: ManifestUpdater 層と同じく、hook の渡し忘れを
        // コンパイルエラーにする。「通知しない」は nil の明示渡しで宣言させる。
        onManifestWrite: (@Sendable () -> Void)?
    ) {
        self.s3 = s3
        self.db = db
        self.syncRoot = syncRoot
        self.deviceId = deviceId
        self.config = config
        self.transferStore = transferStore
        self.progressReporter = progressReporter
        self.uploadLimiter = uploadLimiter
        self.manifestUpdater = ManifestUpdater(
            store: s3, deviceId: deviceId, onManifestDidWrite: onManifestWrite
        )
    }

    /// upload_queue の 1 件を処理する。
    public func process(_ item: UploadQueueRecord) async throws {
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
                    eventType: SyncLogEventType.error.rawValue,
                    path: path,
                    message: "Refusing to upload a symbolic link (skipped)",
                    details: nil
                )
                try log.insert(db)
            }
            AppLogger.sync.error("Refusing to upload a symbolic link: \(path, privacy: .private)")
            return
        } catch let openError as FileOpenError where openError.isPathNoLongerRegularFile {
            // path がもはや通常ファイルを指せない = 削除（ENOENT）/ ディレクトリ化（Issue #52・
            // rm x.txt && mkdir x.txt）/ 祖先のファイル化（ENOTDIR・dir → file 置換の鏡像で
            // stale な子 upload 行が残るケース）→ delete として再処理する。
            // upload のまま 5 回 give-up すると旧エントリの S3 delete が発行されず、マニフェストに
            // 「ファイルと同名配下」が両立する不整合が残る（イベント分類側の種別変化検出が主経路で、
            // ここはスキャン enqueue 済み行・既存 stale 行への防衛層。PR #53 レビュー #5 / nit-1 で
            // ENOTDIR を追加し catch を統合。理由の切り分け用に openError を添える＝再レビュー nit）。
            AppLogger.sync.info("Path no longer names a regular file (\(String(describing: openError), privacy: .private)); converting upload to delete: \(path, privacy: .private)")
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
        // SyncEngine 側でリトライせずに recentIssues へ明示 + キュー除去する（「バックアップされていない」可視化）。
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
            // L6 (A-detect): 開始時 stat（info）を渡し、complete 前に再 stat させる。読込中に変化していたら
            // torn なので complete せず abort + 再開に委ね、fileChangedDuringUpload を投げる。
            let mp = try await MultipartUploader(s3: s3).upload(
                key: s3Key,
                reader: reader,
                partSize: plan.partSize,
                metadata: metadata,
                resume: resume,
                expectedStat: info,
                limiter: uploadLimiter,
                onProgress: onProgress
            )
            sha256 = mp.sha256
            result = mp.put
        } else {
            // シングルパート: 同一 FD から 1 回読んだバッファでハッシュも本体も賄う（2 回 open を畳む）。
            let (data, sha) = try HashCalculator.readAllAndHash(reader)
            // L6 (A-detect): PUT 前に再 stat。読込中にローカルが変化していたら torn なので PUT しない
            // （現行 S3 オブジェクトを torn で上書きしない）。fileChangedDuringUpload を投げ、安定後に上げ直す。
            let afterInfo = try reader.info()
            guard StabilityCheck.isStable(expected: info, final: afterInfo) else {
                throw SyncError.fileChangedDuringUpload(path: path)
            }
            sha256 = sha
            // 帯域制御（サブ E）: 単発 PUT は Data 一括なので、送出前に本体サイズぶんを取得して
            // 平均レートを律速する（≤16MiB なので粒度は粗いが個人利用では十分）。
            await uploadLimiter?.acquire(data.count)
            result = try await s3.putObject(
                key: s3Key,
                data: data,
                contentType: "application/octet-stream",
                metadata: metadata
            )
        }
        AppLogger.s3.info("Uploaded \(path, privacy: .private) (\(size) bytes)")

        // 3. manifest update（Issue #25 / A: 書込直前に権威 entry を読み並行更新を検出）。
        //    base = 最後にローカル DB へ記録した SHA。これと「今上げた sha256」「権威シャードの現リモート sha」を
        //    decideUpload で突き合わせ、.conflict なら uploadConflict を投げて RMW を安全中断する（無音上書きしない）。
        let base = try await db.pool.read { db in
            try FileRecord.fetchOne(db, key: path)?.sha256
        }
        let newEntry = ManifestFileEntry(
            size: size,
            mtime: ISO8601.format(mtimeDate),
            sha256: sha256,
            s3VersionId: result.versionId,
            etag: result.etag,
            deviceId: deviceId,
            uploadedAt: ISO8601.now()
        )
        let outcome = try await manifestUpdater.updateFileEntry(
            for: path, base: base, newEntry: newEntry
        )

        // 4. local DB
        //    .wrote          → 自分の PUT identity（versionId/etag）を記録。
        //    .alreadyUpToDate → 別書き手が確定済みのリモート版 identity を記録し、次回 pull を no-op にする
        //                       （ChangeDetector.reconcileIsNoop の sha/etag/versionId 一致条件を満たす）。
        //    size/sha は両者同一（alreadyUpToDate は remote == uploading ⟹ 同一内容 ⟹ 同一サイズ）。
        //    mtime は常にローカル stat 実値（[mtime 不変条件]: マニフェスト ISO8601 秒精度で上書きしない）。
        let identity: (versionId: String?, etag: String)
        switch outcome {
        case .wrote:
            identity = (result.versionId, result.etag)
        case .alreadyUpToDate(let remote):
            identity = (remote.s3VersionId, remote.etag)
        }
        let now = Date().timeIntervalSince1970
        try await db.pool.write { db in
            var rec = FileRecord(
                path: path,
                size: size,
                mtime: mtime,
                sha256: sha256,
                s3VersionId: identity.versionId,
                s3Etag: identity.etag,
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
                eventType: SyncLogEventType.upload.rawValue,
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

        try await manifestUpdater.updateShard(for: path) { shard in
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
                eventType: SyncLogEventType.delete.rawValue,
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

/// `updateFileEntry` の結果。アップロード書込シームでの並行更新検出（Issue #25 / A）の結末を表す。
public enum ShardUpdateOutcome: Equatable, Sendable {
    /// 自分の entry でマニフェストを更新した。`newShardEtag` は putShard の返り値
    /// （FP 拡張の自世代 append が shardEtags を更新して次回増分ロードの再取得を避ける。5-2）。
    case wrote(newShardEtag: String)
    /// 別の書き手が同一内容を既に確定済みだった（マニフェスト書込せず）。
    /// 付随する `ManifestFileEntry` は権威シャードの現リモート版＝ローカル DB をこの identity に合わせる。
    case alreadyUpToDate(ManifestFileEntry)
}

/// `removeFileEntry` の結果（FP 拡張の deleteItem 用・M5 Phase 5-2）。
public enum ShardRemoveOutcome: Equatable, Sendable {
    /// entry を除去した。`newShardEtag` は残エントリありなら putShard の返り値、
    /// 空シャード削除なら nil（自世代 append は該当シャードを shardEtags から落とす）。
    case removed(newShardEtag: String?)
    /// entry が既に無い（冪等成功。consumed 済み削除の再試行 / 他デバイスが先に削除）。
    case alreadyGone
    /// 権威 entry がベースから進んでいた = 削除拒否（「データ損失 < 重複」）。
    /// 呼び出し側は最新 item を添えて `fileProviderErrorForRejectedDeletion` を返し、
    /// システムに最新版を復元させる。
    case rejectedRemoteChanged(ManifestFileEntry)
}

/// シャードと index.json を楽観的ロックで更新する。
/// アプリ（Uploader 経由）と File Provider 拡張（M5 Phase 5〜）が共有する
/// **マニフェスト書込の唯一のチョークポイント**。
public struct ManifestUpdater: Sendable {
    public let store: any ManifestStore
    public let deviceId: String
    /// マニフェスト（シャード + index）が**実際に書かれた**直後に 1 回発火する。
    /// FP ドメインへの signal はここに配線する（M5 Phase 5-0 / PR #51 レビュー #4）:
    /// バッチ集約（anySucceeded）だと「マニフェスト PUT 成功 → 後続の DB write throw」で
    /// 1 バッチ分 signal が漏れる窓があったが、確定点発火なら構造的に漏れない。
    /// `.alreadyUpToDate`（書いていない）/ `.conflict` / リトライ尽き失敗では発火しない。
    public var onManifestDidWrite: (@Sendable () -> Void)?

    /// `onManifestDidWrite` に既定値を置かない（PR #56 レビュー ④）: 将来の構築箇所
    /// （FP 拡張の書込経路等）が hook の配線を忘れると signal 漏れ窓が静かに再発するため、
    /// 「通知しない」は `nil` の明示渡しで宣言させる。
    public init(
        store: any ManifestStore,
        deviceId: String,
        onManifestDidWrite: (@Sendable () -> Void)?
    ) {
        self.store = store
        self.deviceId = deviceId
        self.onManifestDidWrite = onManifestDidWrite
    }

    /// アップロードの per-file entry を、並行更新を検出しながら書き込む（Issue #25 / A）。
    /// `withConditionalRetry` 内でフェッチ済みシャードの現エントリ（追加 GET なし）を読み、
    /// `decideUpload(base:uploading:remote:)` で判定する:
    /// - `.proceed` → 自分の entry を put（通常 / 再作成）。
    /// - `.alreadyUpToDate` → put せず権威 entry を返す（別書き手が同一内容を確定済み）。
    /// - `.conflict` → `SyncError.uploadConflict` を投げて RMW を安全中断（無音上書きしない）。
    ///
    /// 412/409 で再フェッチされた場合は同 retry 内で `decideUpload` を再評価するため、無音上書きの窓は
    /// 実質ゼロに畳まれる（`uploadConflict` は 412/409 クラシファイアにマッチせず即伝播）。
    public func updateFileEntry(
        for path: String,
        base: String?,
        newEntry: ManifestFileEntry
    ) async throws -> ShardUpdateOutcome {
        let shardId = ManifestSharding.shardId(for: path)
        return try await withConditionalRetry("shard \(shardId)") {
            let fetched = try await store.getShard(shardId)
            var shard = fetched?.value ?? ManifestShard.empty(id: shardId)
            let etag = fetched?.etag
            let existing = shard.files[path]
            let decision = ThreeWayMerge.decideUpload(
                base: base, uploading: newEntry.sha256, remote: existing?.sha256
            )
            // existing は decideUpload が .alreadyUpToDate / .conflict を返すとき必ず非 nil
            // （remote == nil なら必ず .proceed）。理論上不到達の existing == nil は安全側で書込へ倒す。
            if decision == .alreadyUpToDate, let existing {
                // index 突合修復（PR #56 レビュー ①）: 「putShard 成功 → updateIndex 未完」で
                // 失敗した書込の再試行はここに入る（remote == uploading）。そのまま返すと
                // index が旧シャード etag を宣言し続け、全読者（他デバイス pull / FP 増分ロード）から
                // この書込が恒久不可視になる。シャード実 etag と index 宣言がずれていれば
                // index のみ修復し、可視化された確定点として発火する。
                if let fetchedEtag = fetched?.etag {
                    try await repairIndexDeclarationIfStale(
                        shardId: shardId, fetchedEtag: fetchedEtag, count: shard.files.count
                    )
                }
                return .alreadyUpToDate(existing)
            }
            if decision == .conflict, let existing {
                // 競合でも突合修復だけは通す（PR #56 再レビュー (3)）: updateIndex 未完の分断からの
                // 再試行で backoff 中のローカル再編集が「自分の前回書込」と幻影競合するケースは
                // `.alreadyUpToDate` に到達しない。throw の前に書込済み entry の可視化を確定させる
                // （競合解決自体は呼び出し元の退避 + versionId 取得が担う）。
                // 修復失敗（manifestUpdateFailed）が uploadConflict を置換して競合解決が 1 backoff
                // 遅れるのは**意図的な優先順**（PR #56 再々レビュー (e)）: try? で握り潰すと
                // resolveUploadConflict がキュー行を消し、修復未完 = index 恒久 stale が再来する。
                // 遅延側は次試行 + pull 側 .conflictThenDownload が受け止め、データ損失はない。
                if let fetchedEtag = fetched?.etag {
                    try await repairIndexDeclarationIfStale(
                        shardId: shardId, fetchedEtag: fetchedEtag, count: shard.files.count
                    )
                }
                throw SyncError.uploadConflict(path: path, remoteEntry: existing)
            }
            // ここに来るのは .proceed のみ（理論上不到達: .alreadyUpToDate/.conflict は existing 非 nil で
            // 上の if が return/throw する）。万一 decideUpload の不変条件「remote==nil ⟹ .proceed」が
            // 壊れて existing==nil で落ちてくると無音上書きが復活するので、debug で回帰を捕まえる
            // （release は安全側＝自分の entry を書込）。
            assert(decision == .proceed, "decideUpload returned \(decision) with a nil existing entry")

            shard.files[path] = newEntry
            // シャード + index の両方が確定した時のみ発火（commitShardWrite）。putShard 成功 →
            // updateIndex がリトライ尽きで throw した場合は非発火のまま失敗として呼び出し元へ
            // 伝播し（SyncError は外側リトライに再マッチしない）、再試行（キューのバックオフ
            // 再試行）が上の `.alreadyUpToDate` 分岐の index 突合修復で可視化 + 発火する
            // （PR #56 レビュー ①）。
            guard let newEtag = try await commitShardWrite(shardId: shardId, shard: shard, etag: etag) else {
                // 直前に entry を入れたので空シャード削除には到達しない（防御）
                throw SyncError.manifestUpdateFailed("shard \(shardId): unexpected empty-shard commit")
            }
            return .wrote(newShardEtag: newEtag)
        }
    }

    /// FP 拡張の deleteItem（M5 Phase 5-2）用: per-file entry を「権威 entry がベースと一致する
    /// ときのみ」除去する。ガードは RMW 内（`removeFileEntry` を新設した理由）: チェック → 削除の
    /// 間に別書き手が entry を進める窓を、412 リトライごとの再評価で塞ぐ。ベース不明（nil）も
    /// 拒否側へ倒す（「データ損失 < 重複」— 根拠なしに消さない）。
    /// 呼び出し側の順序は **マニフェスト除去 → deleteObject**（アプリの processDelete と逆）:
    /// 権威判定点がこの RMW 内にあるため。中間クラッシュは「マニフェストから消えた不可視 live
    /// オブジェクト」が残るだけ（他デバイスは削除に収束・版履歴で回復可・データ損失なし）。
    public func removeFileEntry(for path: String, base: String?) async throws -> ShardRemoveOutcome {
        let shardId = ManifestSharding.shardId(for: path)
        return try await withConditionalRetry("shard \(shardId)") {
            let fetched = try await store.getShard(shardId)
            var shard = fetched?.value ?? ManifestShard.empty(id: shardId)
            let etag = fetched?.etag
            guard let existing = shard.files[path] else {
                // 不在 = 冪等成功。分断の後始末（index 宣言ずれ / dangling 宣言）だけ突合しておく
                // （updateShard の no-op 経路と同じ規約）。
                if let fetchedEtag = fetched?.etag {
                    try await repairIndexDeclarationIfStale(
                        shardId: shardId, fetchedEtag: fetchedEtag, count: shard.files.count
                    )
                } else {
                    try await removeDanglingDeclarationIfShardAbsent(shardId: shardId)
                }
                return .alreadyGone
            }
            guard let base, existing.sha256 == base else {
                return .rejectedRemoteChanged(existing)
            }
            shard.files.removeValue(forKey: path)
            let newEtag = try await commitShardWrite(shardId: shardId, shard: shard, etag: etag)
            return .removed(newShardEtag: newEtag)
        }
    }

    public func updateShard(
        for path: String,
        transform: (inout ManifestShard) -> Void
    ) async throws {
        let shardId = ManifestSharding.shardId(for: path)
        try await withConditionalRetry("shard \(shardId)") {
            let fetched = try await store.getShard(shardId)
            var shard = fetched?.value ?? ManifestShard.empty(id: shardId)
            let etag = fetched?.etag
            let filesBefore = shard.files
            transform(&shard)

            // no-op 検出（PR #56 レビュー ②）: transform が内容を変えなかったら書かない・発火しない
            // （`updateFileEntry` の `.alreadyUpToDate` と対称の規約）。到達例: マニフェスト不在パスへの
            // delete（consumed 済みの再試行 / 他デバイスが先に削除 / ENOENT からの delete 変換）。
            // ただし「シャード実体と index 宣言のずれ」だけは修復する（PR #56 レビュー ①:
            // 前回試行が updateIndex 手前で失敗した再入では、内容不変でも index 修復が必要）。
            if shard.files == filesBefore {
                if let etag {
                    try await repairIndexDeclarationIfStale(
                        shardId: shardId, fetchedEtag: etag, count: shard.files.count
                    )
                } else {
                    // シャード不在なのに index が宣言を残している（deleteShard 成功 → updateIndex
                    // 失敗の再入）→ dangling 宣言を除去して確定させる。
                    try await removeDanglingDeclarationIfShardAbsent(shardId: shardId)
                }
                return
            }

            _ = try await commitShardWrite(shardId: shardId, shard: shard, etag: etag)
        }
    }

    /// シャード書込の共通テール（updateFileEntry / updateShard / removeFileEntry が共用）:
    /// updatedAt を刻み、空なら deleteShard + 宣言除去、残があれば putShard + 宣言更新。
    /// マニフェストが確定した時のみ発火する。
    /// - 空シャード削除の宣言除去は CAS（PR #56 再々レビュー (b)）: 「自分が消したシャードの
    ///   etag（外側で観測した値）を宣言しているとき」のみ removeValue。deleteShard 〜 コミットの
    ///   間に並行書き手が再作成 + 宣言していたら、その正当な宣言を消さない（実在シャードの
    ///   未宣言化 = removedShards 誤検出 → 削除伝播の遮断）。
    /// - CAS 失敗時は実在再確認付き dangling 除去へフォールスルー（第 4 ラウンド (g)）:
    ///   「先行分断の stale 宣言 + 自分が今オブジェクトを消した」形の ghost 化（削除が伝播しない）
    ///   を防ぎつつ、並行再作成は温存する。
    /// - Returns: putShard した場合はその新 etag。空シャード削除なら nil。
    private func commitShardWrite(
        shardId: String, shard: ManifestShard, etag: String?
    ) async throws -> String? {
        var shard = shard
        shard.updatedAt = ISO8601.now()

        if shard.files.isEmpty {
            if etag != nil {
                try await store.deleteShard(shardId)
            }
            let removed = try await updateIndex { idx in
                guard idx.shards[shardId]?.etag == etag else { return false }
                idx.shards.removeValue(forKey: shardId)
                return true
            }
            if removed {
                onManifestDidWrite?()
            } else {
                try await removeDanglingDeclarationIfShardAbsent(shardId: shardId)
            }
            return nil
        }

        let newEtag = try await store.putShard(shard, ifMatch: etag)
        _ = try await updateIndex { idx in
            idx.shards[shardId] = .init(etag: newEtag, count: shard.files.count)
            return true
        }
        onManifestDidWrite?()
        return newEtag
    }

    /// シャード不在時の dangling 宣言除去（実在再確認 + CAS 付き。PR #56 再レビュー (1) /
    /// 再々レビュー (a) / 第 4 ラウンド (g) で共用ヘルパ化）。
    /// 「オブジェクトは無いのに index が宣言を残している」状態を、観測し直した宣言への CAS で
    /// 除去して確定させる（除去したら発火）。放置すると他デバイスは「宣言 == 記録済み etag」で
    /// スキャンをスキップし続け、削除が伝播しない（ghost 残存）。
    /// - CAS: 観測した宣言から index が動いていたら中止（並行書き手の新しい宣言を消さない =
    ///   実在シャードの未宣言化 → removedShards 誤検出 → 削除伝播の遮断）。
    /// - 実在再確認: 宣言観測より前に並行書き手の再作成（putShard + 宣言）が両方完了していると、
    ///   新鮮な宣言を「stale な dangling」と誤認したまま CAS が成立してしまうため、コミット前に
    ///   シャード実在を再確認して実在なら中止（B の putShard が再確認前 → ここで中止 /
    ///   B の宣言が観測後 → CAS 不成立で中止、の両翼）。
    /// - Returns: 宣言を除去したか。
    @discardableResult
    private func removeDanglingDeclarationIfShardAbsent(shardId: String) async throws -> Bool {
        let declared = try await store.getIndex()?.value.shards[shardId]?.etag
        guard declared != nil else { return false }
        if try await store.getShard(shardId) != nil { return false }
        let removed = try await updateIndex { idx in
            guard idx.shards[shardId]?.etag == declared else { return false }
            idx.shards.removeValue(forKey: shardId)
            return true
        }
        if removed { onManifestDidWrite?() }
        return removed
    }

    /// シャード実 etag と index 宣言を突合し、ずれていれば **CAS 付き**で index のみ修復する
    /// （PR #56 レビュー ① / 再レビュー (1)）。「putShard 成功 → updateIndex 未完」の分断からの
    /// 再入（`.alreadyUpToDate` / `.conflict` / no-op 書換）が呼ぶ。
    /// CAS: 観測した宣言から index が動いていたら修復を中止する（並行書き手の新しい宣言を
    /// stale 観測で巻き戻さない）。中止しても正しさは保たれる — 宣言を動かした書き手が
    /// 自分の書込パスで宣言を確定させている。修復として書いたときのみ発火する。
    /// - Returns: 修復として index を書いたか。
    @discardableResult
    private func repairIndexDeclarationIfStale(
        shardId: String, fetchedEtag: String, count: Int
    ) async throws -> Bool {
        let declared = try await store.getIndex()?.value.shards[shardId]?.etag
        guard declared != fetchedEtag else { return false }
        let repaired = try await updateIndex { idx in
            guard idx.shards[shardId]?.etag == declared else { return false }
            idx.shards[shardId] = .init(etag: fetchedEtag, count: count)
            return true
        }
        if repaired { onManifestDidWrite?() }
        return repaired
    }

    /// index の RMW。`transform` が false を返したら**書かずに** false（CAS 中止用）。
    /// 412/409 リトライは index を再取得してから transform を再評価するので、CAS は毎試行
    /// 新鮮な index に対して判定される。
    /// - Returns: 実際に index を書いたか。
    private func updateIndex(_ transform: (inout ManifestIndex) -> Bool) async throws -> Bool {
        try await withConditionalRetry("index.json") {
            let fetched = try await store.getIndex()
            var index = fetched?.value ?? ManifestIndex.empty(updatedBy: deviceId)
            let etag = fetched?.etag
            guard transform(&index) else { return false }
            index.updatedAt = ISO8601.now()
            index.updatedBy = deviceId
            _ = try await store.putIndex(index, ifMatch: etag)
            return true
        }
    }

    /// シャード / index.json の楽観的ロック更新を共通化したリトライ実行。
    /// 412 PreconditionFailed / 409 ConditionalRequestConflict（同一オブジェクトへの並行更新による
    /// 一時的失敗）は再取得して PUT し直せば解消するので、最大 5 回・100–500ms ランダムバックオフで
    /// リトライする。それ以外のエラーは即時伝播。5 回尽きたら `manifestUpdateFailed(label …)`。
    private func withConditionalRetry<T>(
        _ label: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for _ in 0..<5 {
            do {
                return try await operation()
            } catch {
                // 自前の SyncError は素通しする（PR #56 レビュー ①）。クラシファイアは
                // String(describing:) の部分文字列マッチなので、下位エラー文字列を埋め込む
                // manifestUpdateFailed（内側 updateIndex のリトライ尽き）や path を含む
                // uploadConflict（"file-412.txt" 等）が「リトライ可能な 412」に誤分類されると、
                // 外側再実行が getShard → 自分の書いた entry → .alreadyUpToDate 短絡で
                // 「index 未更新のまま静かな成功」に化ける（恒久 stale の温床）。
                if error is SyncError { throw error }
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
            "\(label) conditional update failed 5 times: \(String(describing: lastError))"
        )
    }
}
