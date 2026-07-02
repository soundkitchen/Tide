import Foundation
import GRDB

// MARK: - Records

public struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var path: String
    public var size: Int64
    public var mtime: Double
    public var sha256: String
    public var s3VersionId: String?
    public var s3Etag: String?
    public var lastSyncedAt: Double?
    public var updatedAt: Double

    public init(path: String, size: Int64, mtime: Double, sha256: String, s3VersionId: String? = nil, s3Etag: String? = nil, lastSyncedAt: Double? = nil, updatedAt: Double) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.sha256 = sha256
        self.s3VersionId = s3VersionId
        self.s3Etag = s3Etag
        self.lastSyncedAt = lastSyncedAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "files"

    public enum CodingKeys: String, CodingKey {
        case path
        case size
        case mtime
        case sha256
        case s3VersionId = "s3_version_id"
        case s3Etag = "s3_etag"
        case lastSyncedAt = "last_synced_at"
        case updatedAt = "updated_at"
    }
}

public struct UploadQueueRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var path: String
    public var operation: String      // "upload" | "delete"
    public var enqueuedAt: Double
    public var attempts: Int
    public var nextRetryAt: Double?
    public var lastError: String?

    public init(id: Int64? = nil, path: String, operation: String, enqueuedAt: Double, attempts: Int, nextRetryAt: Double? = nil, lastError: String? = nil) {
        self.id = id
        self.path = path
        self.operation = operation
        self.enqueuedAt = enqueuedAt
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
    }

    public static let databaseTableName = "upload_queue"

    public enum CodingKeys: String, CodingKey {
        case id
        case path
        case operation
        case enqueuedAt = "enqueued_at"
        case attempts
        case nextRetryAt = "next_retry_at"
        case lastError = "last_error"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ShardStateRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var shardId: String
    public var etag: String
    public var fetchedAt: Double

    public init(shardId: String, etag: String, fetchedAt: Double) {
        self.shardId = shardId
        self.etag = etag
        self.fetchedAt = fetchedAt
    }

    public static let databaseTableName = "shard_state"

    public enum CodingKeys: String, CodingKey {
        case shardId = "shard_id"
        case etag
        case fetchedAt = "fetched_at"
    }
}

/// sync_log の `event_type` の実使用値。書込箇所はリテラルでなくこの rawValue を使う
/// （タイポすると Activity のフィルタから黙って漏れるため）。
public enum SyncLogEventType: String, CaseIterable, Sendable {
    case upload
    case download
    case delete
    case conflict
    case error
    case info
}

public struct SyncLogRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var timestamp: Double
    public var eventType: String      // SyncLogEventType.rawValue
    public var path: String?
    public var message: String
    public var details: String?

    public init(id: Int64? = nil, timestamp: Double, eventType: String, path: String? = nil, message: String, details: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.path = path
        self.message = message
        self.details = details
    }

    public static let databaseTableName = "sync_log"

    public enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case eventType = "event_type"
        case path
        case message
        case details
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// M3 サブ D（中断・再開）: 転送途中の状態を永続化するサイドカー行。
/// アップロード（マルチパート）とダウンロード（Range）で共有し、PK は (path, direction)。
/// 列はどちらの方向でも片側が NULL になり得る。型付き API は `TransferStateStore` 側に置く。
public struct TransferStateRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var path: String
    public var direction: String          // "upload" | "download"
    public var uploadId: String?
    public var partSize: Int?
    public var completedParts: String?    // JSON [{"n":Int,"etag":String}]
    public var tmpPath: String?
    public var bytesDone: Int64?
    public var expectedEtag: String?
    public var fileMtime: Double?
    public var fileSize: Int64?
    public var updatedAt: Double

    public init(path: String, direction: String, uploadId: String? = nil, partSize: Int? = nil, completedParts: String? = nil, tmpPath: String? = nil, bytesDone: Int64? = nil, expectedEtag: String? = nil, fileMtime: Double? = nil, fileSize: Int64? = nil, updatedAt: Double) {
        self.path = path
        self.direction = direction
        self.uploadId = uploadId
        self.partSize = partSize
        self.completedParts = completedParts
        self.tmpPath = tmpPath
        self.bytesDone = bytesDone
        self.expectedEtag = expectedEtag
        self.fileMtime = fileMtime
        self.fileSize = fileSize
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "transfer_state"

    public enum CodingKeys: String, CodingKey {
        case path
        case direction
        case uploadId = "upload_id"
        case partSize = "part_size"
        case completedParts = "completed_parts"
        case tmpPath = "tmp_path"
        case bytesDone = "bytes_done"
        case expectedEtag = "expected_etag"
        case fileMtime = "file_mtime"
        case fileSize = "file_size"
        case updatedAt = "updated_at"
    }
}

// MARK: - Database

/// GRDB の DatabasePool をラップ。Sendable に出来ないので @unchecked Sendable
public final class LocalDatabase: @unchecked Sendable {
    public let pool: DatabasePool

    public init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
        }
        self.pool = try DatabasePool(path: url.path, configuration: config)
        try DBMigrations.makeMigrator().migrate(pool)
    }

    /// 既定の DB パス（App Group コンテナ内・M5 Phase 2 で移設）。
    /// app と将来の File Provider 拡張が同じ DB を共有する。旧ロケーション
    /// （`~/Library/Application Support/Tide/db.sqlite`）からの一度きり移行は
    /// `LegacyStateMigrator` が行う。
    public static func defaultURL() throws -> URL {
        try TideAppGroup.supportDirectoryURL().appendingPathComponent("db.sqlite")
    }

    // MARK: - log

    public func appendLog(type: SyncLogEventType, path: String? = nil, message: String, details: String? = nil) async throws {
        try await pool.write { db in
            var row = SyncLogRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                eventType: type.rawValue,
                path: path,
                message: message,
                details: details
            )
            try row.insert(db)
        }
    }

    /// sync_log の 1 ページ（id 降順 = 新しい順）。
    public struct SyncLogPage: Sendable {
        public var records: [SyncLogRecord]
        public var hasMore: Bool

        public init(records: [SyncLogRecord], hasMore: Bool) {
            self.records = records
            self.hasMore = hasMore
        }
    }

    /// sync_log を新しい順に読む（Sync Activity ウィンドウ用）。
    /// カーソルは `beforeId`（AUTOINCREMENT で単調・一意）。timestamp は REAL の同値衝突が
    /// あり得てページ境界で重複 / 欠落するため使わない。`limit + 1` 件 fetch して hasMore を
    /// 判定する。`eventTypes` nil は全種別（空集合は 0 件）。
    public func fetchLogs(
        eventTypes: Set<SyncLogEventType>? = nil,
        beforeId: Int64? = nil,
        limit: Int = 100
    ) async throws -> SyncLogPage {
        try await pool.read { db in
            var request = SyncLogRecord.order(Column("id").desc)
            if let eventTypes {
                request = request.filter(eventTypes.map(\.rawValue).contains(Column("event_type")))
            }
            if let beforeId {
                request = request.filter(Column("id") < beforeId)
            }
            let rows = try request.limit(limit + 1).fetchAll(db)
            return SyncLogPage(records: Array(rows.prefix(limit)), hasMore: rows.count > limit)
        }
    }

    public func pruneOldLogs(olderThanDays days: Int = 30) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        _ = try pool.write { db in
            try SyncLogRecord
                .filter(Column("timestamp") < cutoff)
                .deleteAll(db)
        }
    }

    /// 診断エクスポート用に、DB の一貫スナップショットを `url` に書き出す（`VACUUM INTO`）。
    /// WAL の内容まで取り込まれた単一ファイルになるので、wal/shm を別途コピーする必要はない。
    /// VACUUM はトランザクション内では実行できないため `writeWithoutTransaction` を使う。
    /// `url` は事前に存在しないこと（`VACUUM INTO` は既存ファイルへは書けない）。
    public func snapshot(to url: URL) async throws {
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM main INTO ?", arguments: [url.path])
        }
    }

    // MARK: - files（mtime 修復）

    /// SHA ゲート（`ChangeDetector.postHash` → `.refreshMtimeOnly`）用の CAS 更新。
    /// 単一 write Tx 内で再フェッチし、`sha256` が判定時の値と一致するときだけ `mtime` /
    /// `updatedAt` を更新する。判定（read → hash）と書込の間に並行 pull の download が
    /// 同 path を更新し得るため、無条件 save だと新しい sha / s3VersionId / s3Etag を
    /// 巻き戻してしまう。`lastSyncedAt` は保持する（tracked 判定・`IgnoreDecision` の
    /// isAlreadyTracked が崩れるため）。
    /// - Returns: 更新したら true（sha 不一致・行消失なら false = no-op）。
    @discardableResult
    public func refreshMtimeIfShaUnchanged(
        path: String, expectedSha: String, newMtime: Double
    ) async throws -> Bool {
        try await pool.write { db in
            guard var rec = try FileRecord.fetchOne(db, key: path),
                  rec.sha256 == expectedSha else { return false }
            rec.mtime = newMtime
            rec.updatedAt = Date().timeIntervalSince1970
            try rec.update(db)
            return true
        }
    }

    // MARK: - upload_queue（L6: 不安定ファイルの延期）

    /// 読込中に変化し続けるファイル（L6 A-detect）の再検査を延期する。`nextRetryAt` だけを前進させ、
    /// **`attempts` と `enqueuedAt` は保持する**: attempts を増やさないことで give-up カウント（5 回で除去）に
    /// 載せず恒久的に未バックアップにしない。enqueuedAt 据え置きは「この保留が安定待ちで何秒経過したか」を
    /// 測る基準（呼び元が再検査間隔を保留経過に比例させる）。処理中に同 path へ新イベントが届いて
    /// INSERT OR REPLACE で新 id 行に置換されていれば fetch で nil → no-op（新行が次周回で処理される）。
    /// 戻り値は更新できたか（行が存在し更新したら true、置換済み/不在なら false）。
    @discardableResult
    public func deferUnstableQueueItem(id: Int64?, nextRetryAt: Double, lastError: String) async throws -> Bool {
        guard let id else { return false }
        return try await pool.write { db in
            guard var rec = try UploadQueueRecord.filter(Column("id") == id).fetchOne(db) else {
                return false
            }
            rec.nextRetryAt = nextRetryAt
            rec.lastError = lastError
            try rec.update(db)
            return true
        }
    }

    // MARK: - shard_state

    /// path が属するシャードの `shard_state` キャッシュを sentinel 化（空 etag）し、次回 pull に
    /// 必ず再 fetch させる。中断・再開（サブ D）の「再 arm」共通機構: 起動時の
    /// `SyncEngine.pruneOrphanTransfers` と、セッション中の DL 失敗（`Downloader.download` の
    /// ネットワーク失敗 catch）の両方から呼ばれる。
    /// 行は削除しない（PR #9 レビュー ③）: `cached[S] = "" ≠ remote etag` で必ず再 fetch させつつ、
    /// S がリモートから丸ごと消えた場合の removed-shard 検出（`removed = cached − remote`）も温存する
    /// （行を消すと S が cached から消え、S 配下の削除伝播が永久に飛ぶ）。空 etag は実 S3 etag と
    /// 衝突しない。行が無ければ no-op（そのシャードは次回 pull で必ず fetch される）。
    public func invalidateShardCache(forPath relativePath: String) async throws {
        let sid = ManifestSharding.shardId(for: relativePath)
        try await pool.write { db in
            if var rec = try ShardStateRecord.fetchOne(db, key: sid) {
                rec.etag = ""
                try rec.update(db)
            }
        }
    }
}
