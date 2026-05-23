# ローカルデータベース仕様

## 概要

ローカル状態管理に SQLite を使用。GRDB.swift をラッパとして採用。

データベースファイルの場所:
```
~/Library/Application Support/Tide/db.sqlite
```

WAL モードで運用。

## テーブル定義

### files

ローカルファイル状態のキャッシュ。FSEvents から差分検出する際の比較対象。

```sql
CREATE TABLE files (
    -- 同期ルートからの相対パス（POSIX 区切り）
    path TEXT NOT NULL PRIMARY KEY,
    
    -- ファイルサイズ（バイト）
    size INTEGER NOT NULL,
    
    -- ファイルの mtime（UNIX エポック秒、小数あり）
    mtime REAL NOT NULL,
    
    -- ファイル内容の SHA-256（hex 小文字）
    sha256 TEXT NOT NULL,
    
    -- S3 アップロード後のメタデータ
    s3_version_id TEXT,
    s3_etag TEXT,
    
    -- 最後に S3 と同期した時刻（UNIX エポック秒）
    last_synced_at REAL,
    
    -- このエントリの最終更新時刻（DB 上）
    updated_at REAL NOT NULL
);

-- last_synced_at がない（=未同期）のエントリを素早く取得するため
CREATE INDEX idx_files_unsynced ON files(path) WHERE last_synced_at IS NULL;
```

### upload_queue

アップロード予約のキュー。アプリ再起動後も処理を継続するための永続化。

```sql
CREATE TABLE upload_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    
    -- 対象ファイルパス
    path TEXT NOT NULL,
    
    -- 操作種別
    operation TEXT NOT NULL CHECK(operation IN ('upload', 'delete')),
    
    -- キューに追加された時刻
    enqueued_at REAL NOT NULL,
    
    -- 試行回数
    attempts INTEGER NOT NULL DEFAULT 0,
    
    -- 次のリトライ時刻（指数バックオフ用）
    next_retry_at REAL,
    
    -- 最後のエラーメッセージ（デバッグ用）
    last_error TEXT,
    
    -- 同じパスのキューエントリは1つだけ
    UNIQUE(path)
);

CREATE INDEX idx_queue_retry ON upload_queue(next_retry_at) 
  WHERE next_retry_at IS NOT NULL;
```

### shard_state

シャードの ETag を覚えておくテーブル。マニフェスト更新時の楽観的ロック用。

```sql
CREATE TABLE shard_state (
    -- シャード ID（2桁 hex）
    shard_id TEXT NOT NULL PRIMARY KEY,
    
    -- このシャードの S3 ETag（最後に取得した時の）
    etag TEXT NOT NULL,
    
    -- 取得時刻
    fetched_at REAL NOT NULL
);
```

### sync_log

同期イベントのログ。トラブルシューティングとUI表示用。古いものは定期削除（30日経過したら）。

```sql
CREATE TABLE sync_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp REAL NOT NULL,
    
    -- 'upload', 'delete', 'error', 'conflict'（M3で使用）, 'info'
    event_type TEXT NOT NULL,
    
    -- 関連ファイルパス（イベントによっては NULL）
    path TEXT,
    
    -- メッセージ
    message TEXT NOT NULL,
    
    -- 追加情報（JSON 文字列）
    details TEXT
);

CREATE INDEX idx_log_timestamp ON sync_log(timestamp DESC);
```

## マイグレーション戦略

GRDB.swift の `DatabaseMigrator` を使用。

```swift
var migrator = DatabaseMigrator()

migrator.registerMigration("v1_initial") { db in
    try db.execute(sql: """
        CREATE TABLE files ( ... );
        CREATE TABLE upload_queue ( ... );
        CREATE TABLE shard_state ( ... );
        CREATE TABLE sync_log ( ... );
        CREATE INDEX ...;
    """)
}

// 将来の変更はここに追加
// migrator.registerMigration("v2_add_xxx") { db in ... }
```

## Swift モデル定義

```swift
import GRDB

struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord {
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

struct UploadQueueRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var path: String
    var operation: String  // "upload" | "delete"
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
}

struct ShardStateRecord: Codable, FetchableRecord, MutablePersistableRecord {
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
```

## 重要なクエリ

### 未同期のファイル取得

```swift
let unsynced = try FileRecord
    .filter(Column("last_synced_at") == nil)
    .fetchAll(db)
```

### リトライ対象のキュー取得

```swift
let now = Date().timeIntervalSince1970
let ready = try UploadQueueRecord
    .filter(Column("next_retry_at") <= now || Column("next_retry_at") == nil)
    .order(Column("enqueued_at"))
    .limit(10)
    .fetchAll(db)
```

### ハッシュキャッシュのヒット判定

ファイルの (size, mtime) が DB と一致したらハッシュ計算スキップ:

```swift
let record = try FileRecord.fetchOne(db, key: relativePath)
let needsHash = record == nil || 
                record?.size != currentSize || 
                abs((record?.mtime ?? 0) - currentMtime) > 0.001
```

mtime 比較で 1ms の許容を入れているのは、ファイルシステムの精度差吸収のため。

## キャッシュサイズの管理

`sync_log` テーブルは無限に増えるので、起動時とアプリアイドル時に定期掃除:

```swift
let cutoff = Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970
try db.execute(sql: "DELETE FROM sync_log WHERE timestamp < ?", arguments: [cutoff])
```

## トランザクション境界

以下の操作は1つのトランザクションで実行:

- ファイルアップロード完了時: `files` 更新 + `upload_queue` 削除 + `sync_log` 追加
- ファイル削除完了時: `files` 削除 + `upload_queue` 削除 + `sync_log` 追加
- リトライ失敗時: `upload_queue` の `attempts` と `next_retry_at` を更新

GRDB の `db.write { ... }` ブロック内で実行する。
