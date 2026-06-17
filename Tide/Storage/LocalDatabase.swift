import Foundation
import GRDB

// MARK: - Records

struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var path: String
    var size: Int64
    var mtime: Double
    var sha256: String
    var s3VersionId: String?
    var s3Etag: String?
    var lastSyncedAt: Double?
    var updatedAt: Double

    static let databaseTableName = "files"

    enum CodingKeys: String, CodingKey {
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

struct UploadQueueRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var path: String
    var operation: String      // "upload" | "delete"
    var enqueuedAt: Double
    var attempts: Int
    var nextRetryAt: Double?
    var lastError: String?

    static let databaseTableName = "upload_queue"

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case operation
        case enqueuedAt = "enqueued_at"
        case attempts
        case nextRetryAt = "next_retry_at"
        case lastError = "last_error"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ShardStateRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var shardId: String
    var etag: String
    var fetchedAt: Double

    static let databaseTableName = "shard_state"

    enum CodingKeys: String, CodingKey {
        case shardId = "shard_id"
        case etag
        case fetchedAt = "fetched_at"
    }
}

/// sync_log の `event_type` の実使用値。書込箇所はリテラルでなくこの rawValue を使う
/// （タイポすると Activity のフィルタから黙って漏れるため）。
enum SyncLogEventType: String, CaseIterable, Sendable {
    case upload
    case download
    case delete
    case conflict
    case error
    case info
}

struct SyncLogRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var timestamp: Double
    var eventType: String      // SyncLogEventType.rawValue
    var path: String?
    var message: String
    var details: String?

    static let databaseTableName = "sync_log"

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case eventType = "event_type"
        case path
        case message
        case details
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// M3 サブ D（中断・再開）: 転送途中の状態を永続化するサイドカー行。
/// アップロード（マルチパート）とダウンロード（Range）で共有し、PK は (path, direction)。
/// 列はどちらの方向でも片側が NULL になり得る。型付き API は `TransferStateStore` 側に置く。
struct TransferStateRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var path: String
    var direction: String          // "upload" | "download"
    var uploadId: String?
    var partSize: Int?
    var completedParts: String?    // JSON [{"n":Int,"etag":String}]
    var tmpPath: String?
    var bytesDone: Int64?
    var expectedEtag: String?
    var fileMtime: Double?
    var fileSize: Int64?
    var updatedAt: Double

    static let databaseTableName = "transfer_state"

    enum CodingKeys: String, CodingKey {
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
final class LocalDatabase: @unchecked Sendable {
    let pool: DatabasePool

    init(at url: URL) throws {
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

    static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("Tide/db.sqlite")
    }

    // MARK: - log

    func appendLog(type: SyncLogEventType, path: String? = nil, message: String, details: String? = nil) async throws {
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
    struct SyncLogPage: Sendable {
        var records: [SyncLogRecord]
        var hasMore: Bool
    }

    /// sync_log を新しい順に読む（Sync Activity ウィンドウ用）。
    /// カーソルは `beforeId`（AUTOINCREMENT で単調・一意）。timestamp は REAL の同値衝突が
    /// あり得てページ境界で重複 / 欠落するため使わない。`limit + 1` 件 fetch して hasMore を
    /// 判定する。`eventTypes` nil は全種別（空集合は 0 件）。
    func fetchLogs(
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

    func pruneOldLogs(olderThanDays days: Int = 30) throws {
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
    func snapshot(to url: URL) async throws {
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
    func refreshMtimeIfShaUnchanged(
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
    func deferUnstableQueueItem(id: Int64?, nextRetryAt: Double, lastError: String) async throws -> Bool {
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
    func invalidateShardCache(forPath relativePath: String) async throws {
        let sid = ManifestSharding.shardId(for: relativePath)
        try await pool.write { db in
            if var rec = try ShardStateRecord.fetchOne(db, key: sid) {
                rec.etag = ""
                try rec.update(db)
            }
        }
    }
}
