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

struct SyncLogRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var timestamp: Double
    var eventType: String      // upload / delete / error / info / conflict
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

    func appendLog(type: String, path: String? = nil, message: String, details: String? = nil) throws {
        try pool.write { db in
            var row = SyncLogRecord(
                id: nil,
                timestamp: Date().timeIntervalSince1970,
                eventType: type,
                path: path,
                message: message,
                details: details
            )
            try row.insert(db)
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
}
