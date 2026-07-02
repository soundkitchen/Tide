import Foundation
import GRDB

/// リモートのマニフェストを `[相対パス: ManifestFileEntry]` に集約して読む。
/// `shard_state` テーブルの etag キャッシュを使い、変化したシャードだけを並列取得する。
public struct ManifestReader {
    public let s3: TideS3Client
    public let db: LocalDatabase

    public init(s3: TideS3Client, db: LocalDatabase) {
        self.s3 = s3
        self.db = db
    }

    public struct ReadResult: Sendable {
        /// 現在のリモート全ファイル。
        public var files: [String: ManifestFileEntry]
        /// 今回新規取得したシャード ID（未参照分も含む）。
        public var updatedShards: Set<String>
        /// 以前は存在したが index から消えていたシャード ID（=配下のファイル全削除）。
        public var removedShards: Set<String>

        public init(files: [String: ManifestFileEntry], updatedShards: Set<String>, removedShards: Set<String>) {
            self.files = files
            self.updatedShards = updatedShards
            self.removedShards = removedShards
        }
    }

    /// index.json + 必要なシャードだけを取得して、リモート全体像を返す。
    /// index.json が存在しなければ空の結果を返す（M2 では fallback 実装はしない）。
    public func read() async throws -> ReadResult? {
        guard let index = try await s3.getIndex() else {
            return ReadResult(files: [:], updatedShards: [], removedShards: [])
        }

        // 直近シャードキャッシュ
        let cached: [String: String] = try await db.pool.read { db in
            let recs = try ShardStateRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: recs.map { ($0.shardId, $0.etag) })
        }

        // M3: シャード ID を厳しく検証して、不正な値（`..`、長い ID 等）が S3 キーに混ざるのを防ぐ
        let validShards: [String: String] = index.value.shards.reduce(into: [:]) { acc, item in
            do {
                try PathValidator.validateShardId(item.key)
                acc[item.key] = item.value.etag
            } catch {
                AppLogger.s3.error("Rejected invalid shard id from manifest: \(item.key, privacy: .private)")
            }
        }
        let remoteShardEtags = validShards

        // 変更検出
        var toFetch: [String] = []
        for (shardId, etag) in remoteShardEtags {
            if cached[shardId] != etag {
                toFetch.append(shardId)
            }
        }
        let removed = Set(cached.keys).subtracting(remoteShardEtags.keys)

        // 並列でシャードを取得（最大 8 並列）。
        // 上限到達時に消費する `group.next()` の結果も**必ず回収する**こと — `_ =` で捨てると
        // 変更シャード数 > 並列上限のとき完了分が失われる。ここでは「未変更シャードは DB から補完」の
        // フォールバックが欠落を偶然マスクするが、捨てられたシャードの shard_state が更新されず
        // 毎周回再取得になる（ManifestSnapshotLoader では実ファイル欠落として顕在化した同型バグ。
        // Phase 3 で両方修正）。
        let fetched = try await withThrowingTaskGroup(of: (String, ManifestShard, String)?.self) { group in
            var acc: [(String, ManifestShard, String)] = []
            var inflight = 0
            let limit = 8
            for shardId in toFetch {
                if inflight >= limit {
                    if let finished = try await group.next(), let item = finished {
                        acc.append(item)
                    }
                    inflight -= 1
                }
                let s3 = self.s3
                group.addTask {
                    guard let f = try await s3.getShard(shardId) else { return nil }
                    return (shardId, f.value, f.etag)
                }
                inflight += 1
            }
            for try await item in group {
                if let item { acc.append(item) }
            }
            return acc
        }

        // shard_state を更新
        try await db.pool.write { db in
            let now = Date().timeIntervalSince1970
            for (shardId, _, etag) in fetched {
                var rec = ShardStateRecord(shardId: shardId, etag: etag, fetchedAt: now)
                try rec.save(db)
            }
            for r in removed {
                try ShardStateRecord.deleteOne(db, key: r)
            }
        }

        // 全ファイルマップ構築
        // - 変更なしシャードは現状不明（cache だけだと中身がない）。M2 では「変更なしシャード」のファイルは
        //   ローカル DB の files テーブルから「最後に同期した状態」として再構築する戦略を使う。
        var files: [String: ManifestFileEntry] = [:]
        for (_, shard, _) in fetched {
            for (path, entry) in shard.files {
                // C1: 取り込み前にパスを検証。不正なら捨てる（ローカル書込まで進ませない）
                do {
                    try PathValidator.validateRelativePath(path)
                    files[path] = entry
                } catch {
                    AppLogger.s3.error("Rejected unsafe path from shard: \(path, privacy: .private)")
                }
            }
        }

        // 変更なしシャード分は files テーブルから補完
        let unchangedShardIds = Set(remoteShardEtags.keys).subtracting(fetched.map { $0.0 })
        if !unchangedShardIds.isEmpty {
            let dbFiles: [FileRecord] = try await db.pool.read { db in
                try FileRecord
                    .filter(Column("last_synced_at") != nil)
                    .fetchAll(db)
            }
            for rec in dbFiles {
                let sid = ManifestSharding.shardId(for: rec.path)
                guard unchangedShardIds.contains(sid) else { continue }
                guard files[rec.path] == nil else { continue }
                files[rec.path] = ManifestFileEntry(
                    size: rec.size,
                    mtime: ISO8601.format(Date(timeIntervalSince1970: rec.mtime)),
                    sha256: rec.sha256,
                    s3VersionId: rec.s3VersionId,
                    etag: rec.s3Etag ?? "",
                    deviceId: "(cached)",
                    uploadedAt: ISO8601.format(Date(timeIntervalSince1970: rec.lastSyncedAt ?? rec.updatedAt))
                )
            }
        }

        return ReadResult(
            files: files,
            updatedShards: Set(fetched.map { $0.0 }),
            removedShards: removed
        )
    }
}
