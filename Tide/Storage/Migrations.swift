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

        // M3 サブ D（中断・再開）: 転送途中の状態をプロセス再起動を跨いで保持するサイドカー。
        // upload_queue（ファイル単位のキュー意味論）とは別レイヤで、アップロード（マルチパート）と
        // ダウンロード（Range 再開）の「ファイル内進捗」を 1 テーブルで扱う。PK は (path, direction)。
        migrator.registerMigration("v2_transfer_state") { db in
            try db.execute(sql: """
                CREATE TABLE transfer_state (
                    -- 同期ルートからの相対パス（POSIX 区切り）
                    path TEXT NOT NULL,
                    -- 転送方向: 'upload' | 'download'
                    direction TEXT NOT NULL CHECK(direction IN ('upload', 'download')),

                    -- === アップロード（マルチパート）再開用 ===
                    -- CreateMultipartUpload が返した UploadId
                    upload_id TEXT,
                    -- 確定したパートサイズ（再開時にオフセットを揃えるため永続化する）
                    part_size INTEGER,
                    -- 完了済みパートの JSON 配列 [{"n":1,"etag":"..."}]
                    completed_parts TEXT,

                    -- === ダウンロード（Range）再開用 ===
                    -- 追記していく決定的な一時ファイルパス
                    tmp_path TEXT,
                    -- これまでに tmp へ書き込めたバイト数（次回 Range の起点）
                    bytes_done INTEGER,
                    -- リモートオブジェクトが変わっていないかの検証（変われば破棄してフル再取得）
                    expected_etag TEXT,

                    -- === 検証スナップショット ===
                    -- アップロード: 再開時にローカルファイルが変わっていないかの照合用
                    file_mtime REAL,
                    file_size INTEGER,

                    updated_at REAL NOT NULL,
                    PRIMARY KEY (path, direction)
                );
                """)
        }
        return migrator
    }
}
