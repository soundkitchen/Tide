import CryptoKit
import Foundation
import TideCore

/// FP 書込経路のオーケストレーション（M5 Phase 5-2・「拡張 = 第 3 のデバイス」方式）。
/// **S3 とマニフェスト（+ 自世代ログ）だけを書く** — アプリの DB / syncRoot / tmp には一切
/// 触れない（[pull/restore 直列化] [mtime 不変条件] に影響しないための境界。docs/08）。
/// マニフェスト書込はアプリと同一チョークポイント（`ManifestUpdater`）を通り、並行更新は
/// If-Match RMW + `decideUpload`/ベースガードが裁く（2 台目 Mac と同型）。
struct ExtensionWriter: Sendable {
    let s3: TideS3Client
    let cache: ManifestGenerationCache
    let updater: ManifestUpdater
    let deviceId: String
    /// 1 ファイルあたりのアップロード上限（`ConfigStore.uploadSizeLimitBytes`）。<=0 は無制限。
    let uploadSizeLimitBytes: Int64
    /// アップロード帯域制御（`ConfigStore.uploadBandwidthBytesPerSec`・PR #58 レビュー #7）。
    /// アプリと同じく設定上限を尊重する。拡張はループを持たず短命なので、レートは
    /// `ExtensionServices` 構築時（= 設定読込時）の値で固定する。<=0 は無制限。
    let uploadLimiter: RateLimiter

    enum ModifyOutcome {
        /// 書込成功（または別書き手が同一内容を確定済み）。entry は正規パスの確定 identity。
        case written(ManifestFileEntry)
        /// 並行更新と競合: ローカル編集は copyPath へ退避済み・リモートが正規パスで勝つ
        /// （FSEvents 側 `resolveUploadConflict` と対称）。
        case conflict(remote: ManifestFileEntry, copyPath: String, copyEntry: ManifestFileEntry)
    }

    enum DeleteOutcome {
        case removed
        case alreadyGone
        /// リモートがベースより進んでいた = 削除拒否（呼び出し側が最新 item を添えて返す）。
        case rejected(ManifestFileEntry)
    }

    enum DirectoryDeleteOutcome {
        /// 配下の追跡ファイルをすべて除去した（`count` = マニフェストから除去した件数）。
        case removed(count: Int)
        /// `path` の権威 entry がベースより進んでいた = 中断（「拒否で即中断」・M5 Phase 5-3）。
        /// 呼び出し側は `DirectoryNotEmpty` を返し、システムに dir と残存分を復元させる。
        case rejected(path: String, remote: ManifestFileEntry)
    }

    /// ファイル内容の書込（modifyItem の .contents、および createItem = `baseSha: nil`・M5 Phase 5-3）。
    /// - Parameters:
    ///   - contentsURL: 新しい内容。nil = 内容なしの createItem（空ファイルとして PUT する）。
    ///   - baseSha: システムが最後に見た itemVersion 由来の sha（3-way ベース）。新規作成は nil —
    ///     `decideUpload(base: nil)` が「リモート不在 = 作成 / 同一 sha = 冪等 / 別内容 = 競合」を裁く。
    ///   - contentModified: システム提供の contentModificationDate（無ければ now）。
    func modifyFileContents(
        path: String, contentsURL: URL?, baseSha: String?, contentModified: Date?
    ) async throws -> ModifyOutcome {
        try PathValidator.validateRelativePath(path)
        let entry = try await uploadObject(
            path: path, contentsURL: contentsURL, contentModified: contentModified
        )
        do {
            let outcome = try await updater.updateFileEntry(for: path, base: baseSha, newEntry: entry)
            // .wrote / .alreadyUpToDate いずれも S3 は確定済み。キャッシュを無効化して次の列挙が
            // S3 から読み直す（局所世代構築は撤去。PR #58 レビュー #2/#3）。
            // .alreadyUpToDate（別書き手が同一 sha を先に確定）でも invalidate する: 自分は書いて
            // いないが**リモートが分岐している**帰結なので、読み直しでその版を反映する（sha 同一なので
            // itemVersion は不変 = 実質 no-op に収束・無害。PR #58 再レビュー参考 1 への意図的据え置き）。
            await cache.invalidateAfterLocalWrite()
            switch outcome {
            case .wrote:
                return .written(entry)
            case .alreadyUpToDate(let remote):
                return .written(remote)
            }
        } catch let SyncError.uploadConflict(_, remoteEntry) {
            // 競合解決（FSEvents 側と対称・回復可能順序）: ローカル編集内容を conflict copy の
            // 別 path として上げ直し（tmp はコールバック中は生存）、正規パスはリモート版が勝つ。
            // 自分が直前に PUT した正規キーの版は orphan version として版履歴に残る（無害・
            // docs/04 のアップロード競合と同じ扱い）。
            let copyPath = ConflictNamer.localCopyRelativePath(for: path)
            try PathValidator.validateRelativePath(copyPath)
            let copyEntry = try await uploadObject(
                path: copyPath, contentsURL: contentsURL, contentModified: contentModified
            )
            let copyOutcome = try await updater.updateFileEntry(
                for: copyPath, base: nil, newEntry: copyEntry
            )
            guard case .wrote = copyOutcome else {
                // conflict copy 名は秒精度タイムスタンプ付きで衝突は実質ない。万一衝突したら
                // 退避を諦めて競合を伝播（リトライは fileproviderd が担う。ローカル編集内容は
                // 正規キーの orphan version として S3 に残っており消失はしない）。
                throw SyncError.uploadConflict(path: path, remoteEntry: remoteEntry)
            }
            await cache.invalidateAfterLocalWrite()
            return .conflict(remote: remoteEntry, copyPath: copyPath, copyEntry: copyEntry)
        }
    }

    /// ディレクトリ再帰削除（deleteItem の dir 版・M5 Phase 5-3）。
    /// - マニフェスト除去は `ManifestUpdater.removeFileEntries` のシャード単位バッチ RMW
    ///   （往復はファイル数ではなくシャード数で有界 ≤256 = deleteItem の「数秒以内」契約に収める）。
    /// - ベースガードは RMW 内・「拒否で即中断」（部分シャードを作らない）。拒否時も先行シャードの
    ///   除去分は確定済み（ベース一致 = 未変更ファイルのみなので安全）なので marker は発行する。
    /// - 順序 = マニフェスト除去 → deleteObject（marker）は単発 `deleteFile` と同じ
    ///   （権威判定点が RMW 内・marker 失敗は削除成功扱い）。
    /// - Parameter expectedByPath: 配下の相対パス → 期待 sha256（呼び出し側がキャッシュ済み
    ///   ツリーから取る。ツリー由来 = リモート由来なので S3 キー組み立て前に全件検証する）。
    func deleteDirectory(expecting expectedByPath: [String: String]) async throws -> DirectoryDeleteOutcome {
        for path in expectedByPath.keys {
            try PathValidator.validateRelativePath(path)
        }
        let outcome = try await updater.removeFileEntries(expecting: expectedByPath)
        let removedPaths: [String]
        let result: DirectoryDeleteOutcome
        switch outcome {
        case .removed(let paths):
            removedPaths = paths
            result = .removed(count: paths.count)
        case .rejected(let path, let remote, let partial):
            removedPaths = partial
            result = .rejected(path: path, remote: remote)
        }
        if !removedPaths.isEmpty {
            // marker 発行（限定並列・失敗はログのみ = 単発 deleteFile と同じ規約）
            let s3 = self.s3
            await withTaskGroup(of: Void.self) { group in
                var pending = removedPaths[...]
                for _ in 0..<min(4, pending.count) {
                    guard let path = pending.popFirst() else { break }
                    group.addTask { await Self.emitDeleteMarker(s3: s3, path: path) }
                }
                while await group.next() != nil {
                    guard let path = pending.popFirst() else { continue }
                    group.addTask { await Self.emitDeleteMarker(s3: s3, path: path) }
                }
            }
            // マニフェストを実際に書いた（= 世代が進むべき）ときだけ無効化 + 自己 signal
            await cache.invalidateAfterLocalWrite()
        }
        return result
    }

    private static func emitDeleteMarker(s3: TideS3Client, path: String) async {
        do {
            try await s3.deleteObject(key: "files/\(path)")
        } catch {
            AppLogger.fileProvider.error("deleteObject after manifest removal failed (invisible live object remains): \(String(describing: error), privacy: .private)")
        }
    }

    /// ファイル削除（deleteItem）。順序 = マニフェスト除去（ベースガードは RMW 内）→
    /// deleteObject（delete marker）。marker 発行の失敗は削除成功扱い（マニフェスト = 真実は
    /// 除去済み・他デバイスは削除に収束・不可視 live は版履歴で回復可）。
    func deleteFile(path: String, baseSha: String?) async throws -> DeleteOutcome {
        try PathValidator.validateRelativePath(path)
        let outcome = try await updater.removeFileEntry(for: path, base: baseSha)
        switch outcome {
        case .removed:
            do {
                try await s3.deleteObject(key: "files/\(path)")
            } catch {
                AppLogger.fileProvider.error("deleteObject after manifest removal failed (invisible live object remains): \(String(describing: error), privacy: .private)")
            }
            await cache.invalidateAfterLocalWrite()
            return .removed
        case .alreadyGone:
            // 別デバイスが先に削除済み等でエントリが既に無い帰結。invalidate は無駄ではない —
            // キャッシュがまだそのファントムを持っていれば読み直しで消える（有益。PR #58 再レビュー
            // 参考 1: この帰結で発火を絞ると、絞った側がファントム除去の機会を失う）。
            await cache.invalidateAfterLocalWrite()
            return .alreadyGone
        case .rejectedRemoteChanged(let remote):
            // 除去していない = 世代を触らない（キャッシュはそのまま = 最新版の item を保持）。
            return .rejected(remote)
        }
    }

    /// S3 への本体アップロード 1 回分（アプリ側 `Uploader.processUpload` の S3 レグと対称・
    /// DB 簿記なし）。fileproviderd 提供の tmp は静止が契約だが `NoFollowFileReader` で開く
    /// （多層防御）。サイズ上限・SSE-S3（putObject/MPU 内で明示）・sha256 は同一規約。
    /// `contentsURL == nil` は内容なしの createItem = 空ファイルを単発 PUT（M5 Phase 5-3）。
    private func uploadObject(
        path: String, contentsURL: URL?, contentModified: Date?
    ) async throws -> ManifestFileEntry {
        guard let contentsURL else {
            let put = try await s3.putObject(key: "files/\(path)", data: Data())
            return ManifestFileEntry(
                size: 0,
                mtime: ISO8601.format(contentModified ?? Date()),
                sha256: HashCalculator.hex(SHA256.hash(data: Data())),
                s3VersionId: put.versionId,
                etag: put.etag,
                deviceId: deviceId,
                uploadedAt: ISO8601.now()
            )
        }
        let reader = try NoFollowFileReader(path: contentsURL.path)
        defer { reader.close() }
        let info = try reader.info()
        guard PartPlan.isWithinUploadLimit(size: info.size, limitBytes: uploadSizeLimitBytes) else {
            throw SyncError.fileTooLarge(path: path, size: info.size)
        }
        let key = "files/\(path)"
        let put: TideS3Client.PutObjectResult
        let sha256: String
        if PartPlan.shouldUseMultipart(fileSize: info.size) {
            let plan = PartPlan.plan(forFileSize: info.size)
            let result = try await MultipartUploader(s3: s3).upload(
                key: key, reader: reader, partSize: plan.partSize, limiter: uploadLimiter
            )
            put = result.put
            sha256 = result.sha256
        } else {
            let (data, hash) = try HashCalculator.readAllAndHash(reader)
            // 単発 PUT は Data 一括なので、送出前に本体サイズぶんを取得して平均レートを律速する
            // （アプリ側 Uploader と同じ規約）。無制限（rate<=0）なら即返る。
            await uploadLimiter.acquire(data.count)
            put = try await s3.putObject(key: key, data: data)
            sha256 = hash
        }
        return ManifestFileEntry(
            size: info.size,
            mtime: ISO8601.format(contentModified ?? Date()),
            sha256: sha256,
            s3VersionId: put.versionId,
            etag: put.etag,
            deviceId: deviceId,
            uploadedAt: ISO8601.now()
        )
    }
}
