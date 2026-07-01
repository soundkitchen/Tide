import Foundation
import CryptoKit

/// 復元先の決定（ハイブリッド方式）。
/// - `.writeOriginal`: 原パスに書き戻す（ローカルが無い / 最後に同期した内容のまま＝上書きしても損失なし）。
/// - `.divertToCopy`: 別名 `(restored ...)` に退避する（未同期のローカル編集を上書きしない）。
public enum RestoreDestination: Equatable, Sendable {
    case writeOriginal
    case divertToCopy
}

/// 復元先を「ローカル現況」と「DB に記録した最後の同期 SHA」から決める純粋ロジック。
/// 副作用ゼロ・全分岐を `RestoreTargetTests` で固定する（`ThreeWayMerge` / `ChangeDetector` と同じパターン）。
///
/// 大原則「データ損失より重複」: ローカルに未同期の編集がある（= 現在 SHA が DB 記録と食い違う）か、
/// 読めない（symlink / I/O エラー）ときは、その編集を上書きせず別名へ退避する。
public enum RestoreTarget {
    /// - Parameters:
    ///   - localExists: 原パスにローカルファイルが存在するか。
    ///   - localSha: 原パスの現在 SHA（存在し読めるとき）。存在しない / 読めない（symlink 含む）は nil。
    ///   - dbRecordSha: `FileRecord.sha256`（最後に同期した内容）。未追跡は nil。
    public static func decide(localExists: Bool, localSha: String?, dbRecordSha: String?) -> RestoreDestination {
        // ローカルに何も無い → 上書き対象が無いので原パスへ。
        guard localExists else { return .writeOriginal }
        // 存在するが読めない（symlink / 権限 / I/O）→ 安全側で退避。
        guard let localSha else { return .divertToCopy }
        // 現在の内容が最後に同期した内容と一致 → 未同期編集なし。上書きしても損失なし。
        if let dbRecordSha, dbRecordSha == localSha { return .writeOriginal }
        // 未同期の編集 or 未追跡（DB 記録なし）→ 退避。
        return .divertToCopy
    }
}

/// 復元の履歴ダウンロードに必要な S3 最小シーム（versionId 指定の HEAD / ストリーミング GET）。
/// 本番は `TideS3Client` が適合し、テストはフェイクを差し込んで（ネットワーク無しで）復元ロジックを検証する。
/// `RangedDownloadClient`（DL 経路）とは別に切る（こちらは HEAD を含み、復元専用）。
public protocol VersionedObjectClient: Sendable {
    func headObject(key: String, versionId: String?) async throws -> TideS3Client.ObjectHead?
    func streamObject(
        key: String,
        versionId: String?,
        rangeStart: Int64?,
        limiter: RateLimiter?,
        sink: (Data) throws -> Void
    ) async throws -> TideS3Client.StreamObjectResult?
}

extension TideS3Client: VersionedObjectClient {}

/// 「選んだ key + versionId をローカル syncRoot に書き戻す」復元サービス。
///
/// 方式は「ローカルへ書き戻し → 再アップロード」: 復元後は通常の FileWatcher → upload 経路に委ねるので
/// **DB は触らない**（スキーマ変更なし）。再アップロードで新マニフェストに sha256 が載り、整合性は既存保証へ合流する。
///
/// 過去版にはマニフェスト sha256 が無い（マニフェストは現行状態のみ）ため、整合性は SHA 突合ではなく
/// `headObject(versionId:)` の真実サイズで担保する（ローカルディスク枯渇 DoS ガード = M7 を復元でも維持）。
public struct RestoreService {
    public let client: any VersionedObjectClient
    public let db: LocalDatabase
    public let syncRoot: URL
    public let tmpDir: URL
    /// ダウンロード帯域制御（サブ E）。`SyncEngine` 保持の共有リミッタを注入。nil = 無制限。
    public var downloadLimiter: RateLimiter? = nil

    public init(
        client: any VersionedObjectClient,
        db: LocalDatabase,
        syncRoot: URL,
        tmpDir: URL,
        downloadLimiter: RateLimiter? = nil
    ) {
        self.client = client
        self.db = db
        self.syncRoot = syncRoot
        self.tmpDir = tmpDir
        self.downloadLimiter = downloadLimiter
    }

    public struct RestoreResult: Sendable, Equatable {
        /// 実際に書き込んだ相対パス（原パス、または別名退避先）。
        public let writtenRelativePath: String
        /// 別名へ退避したか（未同期編集を守った）。
        public let diverted: Bool
        /// 書き込んだバイト数。
        public let bytes: Int64

        public init(writtenRelativePath: String, diverted: Bool, bytes: Int64) {
            self.writtenRelativePath = writtenRelativePath
            self.diverted = diverted
            self.bytes = bytes
        }
    }

    /// サイズ上限超過など「破棄して仕切り直すべき」失敗。
    private enum RestoreAbort: Error {
        case tooLarge
    }

    /// `relativePath` の `versionId`（nil = 最新版）をローカルへ復元する。
    /// - Returns: 書き込んだ相対パスと退避有無。
    @discardableResult
    public func restore(relativePath: String, versionId: String?) async throws -> RestoreResult {
        // リモート由来 key の再検証（B の純粋関数で除外済みだが入口で必ず通す）。
        try PathValidator.validateRelativePath(relativePath)
        let s3Key = "files/\(relativePath)"

        // 1. HEAD で真実サイズを取得（履歴版にマニフェスト entry.size が無いため）。
        guard let head = try await client.headObject(key: s3Key, versionId: versionId) else {
            throw Self.notFoundError(key: s3Key)
        }
        guard let expectedSize = head.size, expectedSize >= 0 else {
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.RestoreService", code: -40,
                userInfo: [NSLocalizedDescriptionKey: "missing content length for key \(s3Key)"]
            ))
        }

        // 2. 復元先決定（ハイブリッド）。原パスのローカル現況と DB 記録 SHA を突合。
        let originalURL = try PathValidator.resolveForWrite(relativePath: relativePath, syncRoot: syncRoot)
        let localExists = FileManager.default.fileExists(atPath: originalURL.path)
        let localSha: String?
        if localExists, !PathValidator.isSymbolicLink(at: originalURL) {
            localSha = try? HashCalculator.sha256(of: originalURL)
        } else {
            // 不在 or symlink（読まない）→ nil。decide() 側で原パス / 退避へ振り分ける。
            localSha = nil
        }
        let dbSha = try await db.pool.read { db in
            try FileRecord.fetchOne(db, key: relativePath)?.sha256
        }
        let destination = RestoreTarget.decide(
            localExists: localExists, localSha: localSha, dbRecordSha: dbSha
        )
        let targetRelative: String
        switch destination {
        case .writeOriginal:
            targetRelative = relativePath
        case .divertToCopy:
            targetRelative = try uniqueRestoredRelativePath(for: relativePath)
        }

        // 3. tmp へストリーミング DL（復元専用 tmp 名・symlink 非追従・サイズ上限ガード）。
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpURL = restoreTmpURL(for: targetRelative, versionId: versionId)
        try? FileManager.default.removeItem(at: tmpURL)  // 残骸があれば消す（O_EXCL で fresh 作成するため）
        let handle = try Downloader.openTmpForWriting(at: tmpURL, append: false)
        var total: Int64 = 0
        do {
            let result = try await client.streamObject(
                key: s3Key, versionId: versionId, rangeStart: nil, limiter: downloadLimiter
            ) { chunk in
                total += Int64(chunk.count)
                // 真実サイズ超過は即破棄（巨大本文でローカルディスクを枯渇させない）。
                if total > expectedSize { throw RestoreAbort.tooLarge }
                try handle.write(contentsOf: chunk)
            }
            try handle.synchronize()
            try handle.close()
            guard result != nil else {
                try? FileManager.default.removeItem(at: tmpURL)
                throw Self.notFoundError(key: s3Key)
            }
        } catch is RestoreAbort {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
            AppLogger.s3.error("Restore exceeded expected size: \(relativePath, privacy: .private)")
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.RestoreService", code: -41,
                userInfo: [NSLocalizedDescriptionKey: "restored body exceeds expected size for key \(s3Key)"]
            ))
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }

        // 4. 実サイズ突合（HEAD のサイズと一致しなければ破棄）。
        let actualSize = Downloader.fileSize(at: tmpURL) ?? -1
        guard actualSize == expectedSize else {
            try? FileManager.default.removeItem(at: tmpURL)
            AppLogger.s3.error("Restore size mismatch (\(actualSize) != \(expectedSize)): \(relativePath, privacy: .private)")
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.RestoreService", code: -42,
                userInfo: [NSLocalizedDescriptionKey: "restored file size mismatch for key \(s3Key)"]
            ))
        }

        // 5. commit: 書込先を resolveForWrite で再解決 + symlink 拒否 + atomic move。
        let targetURL = try PathValidator.resolveForWrite(relativePath: targetRelative, syncRoot: syncRoot)
        if PathValidator.isSymbolicLink(at: targetURL) {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.RestoreService", code: -43,
                userInfo: [NSLocalizedDescriptionKey: "restore target is a symbolic link; refusing to write"]
            ))
        }
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // rename(2) 自体は atomic だが、remove → move のシーケンス全体としては非 atomic（間でクラッシュ
        // すると原本が消え tmp が残る）。Downloader と同型の許容トレードオフ: writeOriginal の原本は
        // 「最後に同期した内容」＝ S3 現行版から回復できる（replaceItemAt は sb-* で FSEvents を汚すので使わない）。
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: targetURL)

        AppLogger.sync.info(
            "Restored \(relativePath, privacy: .private) → \(targetRelative, privacy: .private) (bytes=\(actualSize))"
        )
        // DB は触らない: FileWatcher が拾って通常 upload 経路で新しい現行版として上げ直す。
        return RestoreResult(
            writtenRelativePath: targetRelative,
            diverted: destination == .divertToCopy,
            bytes: actualSize
        )
    }

    // MARK: - helpers

    /// 復元専用の決定的 tmp 名。`Downloader` の `dl-...` とも、別 versionId の復元とも衝突しないよう
    /// 対象相対パス + versionId をハッシュする。
    private func restoreTmpURL(for targetRelative: String, versionId: String?) -> URL {
        let seed = "\(targetRelative)\u{0}\(versionId ?? "latest")"
        let h = HashCalculator.hex(SHA256.hash(data: Data(seed.utf8)))
        return tmpDir.appendingPathComponent("restore-\(h).part")
    }

    /// 退避先の相対パス（`(restored ...)`）。同名が既にあればサフィックス時刻をずらして避ける。
    private func uniqueRestoredRelativePath(for relativePath: String) throws -> String {
        let now = Date()
        var candidate = ConflictNamer.restoredCopyRelativePath(for: relativePath, at: now)
        try PathValidator.validateRelativePath(candidate)
        var tries = 0
        while FileManager.default.fileExists(atPath: syncRoot.appendingPathComponent(candidate).path) {
            tries += 1
            if tries > 10 {
                throw SyncError.ioError(underlying: NSError(
                    domain: "Tide.RestoreService", code: -44,
                    userInfo: [NSLocalizedDescriptionKey: "could not find non-conflicting restore name for \(relativePath)"]
                ))
            }
            candidate = ConflictNamer.restoredCopyRelativePath(
                for: relativePath, at: now.addingTimeInterval(Double(tries))
            )
        }
        return candidate
    }

    private static func notFoundError(key: String) -> SyncError {
        SyncError.ioError(underlying: NSError(
            domain: "Tide.RestoreService", code: -45,
            userInfo: [NSLocalizedDescriptionKey: "version not found on S3 for key \(key)"]
        ))
    }
}
