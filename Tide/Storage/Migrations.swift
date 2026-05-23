import Foundation
import GRDB

enum DBMigrations {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    path TEXT NOT NULL PRIMARY KEY,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    sha256 TEXT NOT NULL,
                    s3_version_id TEXT,
                    s3_etag TEXT,
                    last_synced_at REAL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX idx_files_unsynced ON files(path) WHERE last_synced_at IS NULL;

                CREATE TABLE upload_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL,
                    operation TEXT NOT NULL CHECK(operation IN ('upload', 'delete')),
                    enqueued_at REAL NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    next_retry_at REAL,
                    last_error TEXT,
                    UNIQUE(path)
                );
                CREATE INDEX idx_queue_retry ON upload_queue(next_retry_at)
                    WHERE next_retry_at IS NOT NULL;

                CREATE TABLE shard_state (
                    shard_id TEXT NOT NULL PRIMARY KEY,
                    etag TEXT NOT NULL,
                    fetched_at REAL NOT NULL
                );

                CREATE TABLE sync_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    event_type TEXT NOT NULL,
                    path TEXT,
                    message TEXT NOT NULL,
                    details TEXT
                );
                CREATE INDEX idx_log_timestamp ON sync_log(timestamp DESC);
                """)
        }
        return migrator
    }
}
