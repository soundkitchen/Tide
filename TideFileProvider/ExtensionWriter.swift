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

    /// 既存ファイルの内容更新（modifyItem の .contents）。
    /// - Parameters:
    ///   - baseSha: システムが最後に見た itemVersion 由来の sha（3-way ベース）。
    ///   - contentModified: システム提供の contentModificationDate（無ければ now）。
    func modifyFileContents(
        path: String, contentsURL: URL, baseSha: String?, contentModified: Date?
    ) async throws -> ModifyOutcome {
        try PathValidator.validateRelativePath(path)
        let entry = try await uploadObject(
            path: path, contentsURL: contentsURL, contentModified: contentModified
        )
        do {
            let outcome = try await updater.updateFileEntry(for: path, base: baseSha, newEntry: entry)
            switch outcome {
            case .wrote(let newShardEtag):
                await cache.recordLocalChange(
                    updatingShardEtags: [ManifestSharding.shardId(for: path): newShardEtag]
                ) { $0[path] = entry }
                return .written(entry)
            case .alreadyUpToDate(let remote):
                // 別書き手が同一内容を確定済み。リモート identity を正として世代へ反映
                // （シャードは書いていないので etag は落として次回突合に委ねる）。
                await cache.recordLocalChange(
                    updatingShardEtags: [ManifestSharding.shardId(for: path): nil]
                ) { $0[path] = remote }
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
            guard case .wrote(let copyShardEtag) = copyOutcome else {
                // conflict copy 名は秒精度タイムスタンプ付きで衝突は実質ない。万一衝突したら
                // 退避を諦めて競合を伝播（リトライは fileproviderd が担う。ローカル編集内容は
                // 正規キーの orphan version として S3 に残っており消失はしない）。
                throw SyncError.uploadConflict(path: path, remoteEntry: remoteEntry)
            }
            await cache.recordLocalChange(
                updatingShardEtags: [
                    ManifestSharding.shardId(for: path): nil,
                    ManifestSharding.shardId(for: copyPath): copyShardEtag,
                ]
            ) { files in
                files[path] = remoteEntry
                files[copyPath] = copyEntry
            }
            return .conflict(remote: remoteEntry, copyPath: copyPath, copyEntry: copyEntry)
        }
    }

    /// ファイル削除（deleteItem）。順序 = マニフェスト除去（ベースガードは RMW 内）→
    /// deleteObject（delete marker）。marker 発行の失敗は削除成功扱い（マニフェスト = 真実は
    /// 除去済み・他デバイスは削除に収束・不可視 live は版履歴で回復可）。
    func deleteFile(path: String, baseSha: String?) async throws -> DeleteOutcome {
        try PathValidator.validateRelativePath(path)
        let outcome = try await updater.removeFileEntry(for: path, base: baseSha)
        switch outcome {
        case .removed(let newShardEtag):
            do {
                try await s3.deleteObject(key: "files/\(path)")
            } catch {
                AppLogger.fileProvider.error("deleteObject after manifest removal failed (invisible live object remains): \(String(describing: error), privacy: .private)")
            }
            await cache.recordLocalChange(
                updatingShardEtags: [ManifestSharding.shardId(for: path): newShardEtag]
            ) { $0.removeValue(forKey: path) }
            return .removed
        case .alreadyGone:
            await cache.recordLocalChange(updatingShardEtags: [:]) { $0.removeValue(forKey: path) }
            return .alreadyGone
        case .rejectedRemoteChanged(let remote):
            return .rejected(remote)
        }
    }

    /// S3 への本体アップロード 1 回分（アプリ側 `Uploader.processUpload` の S3 レグと対称・
    /// DB 簿記なし）。fileproviderd 提供の tmp は静止が契約だが `NoFollowFileReader` で開く
    /// （多層防御）。サイズ上限・SSE-S3（putObject/MPU 内で明示）・sha256 は同一規約。
    private func uploadObject(
        path: String, contentsURL: URL, contentModified: Date?
    ) async throws -> ManifestFileEntry {
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
                key: key, reader: reader, partSize: plan.partSize
            )
            put = result.put
            sha256 = result.sha256
        } else {
            let (data, hash) = try HashCalculator.readAllAndHash(reader)
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
