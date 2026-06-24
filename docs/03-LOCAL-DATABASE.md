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
    
    -- 'upload', 'download', 'delete', 'error', 'conflict'（M3で使用）, 'info'
    event_type TEXT NOT NULL,
    
    -- 関連ファイルパス（イベントによっては NULL）
    path TEXT,
    
    -- メッセージ
    message TEXT NOT NULL,
    
    -- 追加情報
    details TEXT
);

CREATE INDEX idx_log_timestamp ON sync_log(timestamp DESC);
```

書込・読出の規約（M4・2026-06-11）:

- `event_type` の実使用値は `SyncLogEventType` enum（`LocalDatabase.swift`）に集約し、書込箇所はリテラルでなく rawValue を使う（タイポすると UI フィルタから黙って漏れるため）。
- **エラー行は `message` = 英語固定文（操作の文脈。例 "Remote pull failed"）、`details` = 生エラー全文**に分離する。生エラーを `message` に埋め込まない（F4 / H2 と同じ整理。UI 既定表示は message のみ・details はオンデマンド）。
- 読出は `LocalDatabase.fetchLogs(eventTypes:beforeId:limit:)`（Sync Activity ウィンドウ用）。**id 降順 + `beforeId` カーソル**でページングする（id は AUTOINCREMENT で単調・一意。timestamp は REAL の同値衝突がありページ境界で重複/欠落し得るため使わない）。`limit + 1` 件 fetch して `hasMore` を判定する。

### transfer_state（M3 サブ D・中断/再開）

転送途中の状態をプロセス再起動を跨いで保持するサイドカー。`upload_queue`（ファイル単位のキュー意味論）とは別レイヤで、アップロード（マルチパート）の `UploadId`＋完了パートと、ダウンロード（Range）の途中バイト数を **1 テーブルで両方向**扱う。PK は `(path, direction)` で、方向ごとに片側の列群が NULL になり得る。`completed_parts` は `[{"n":Int,"etag":String}]` の JSON。型付きアクセスは `TransferStateStore`。

```sql
CREATE TABLE transfer_state (
    path TEXT NOT NULL,
    direction TEXT NOT NULL CHECK(direction IN ('upload', 'download')),

    -- アップロード（マルチパート）再開用
    upload_id TEXT,          -- CreateMultipartUpload が返した UploadId
    part_size INTEGER,       -- 確定したパートサイズ（再開時にオフセットを揃える）
    completed_parts TEXT,    -- 完了済みパートの JSON 配列

    -- ダウンロード（Range）再開用
    tmp_path TEXT,           -- 追記していく決定的な一時ファイルパス
    bytes_done INTEGER,      -- 直近に把握した進捗バイト数（失敗時に記録＝updated_at の heartbeat。再開起点は tmp 実サイズを真実とする）
    expected_etag TEXT,      -- リモートが変わっていないかの検証（変われば破棄して再取得）

    -- 検証スナップショット（アップロード: 再開時にローカルが変わっていないか照合）
    file_mtime REAL,
    file_size INTEGER,

    updated_at REAL NOT NULL,
    PRIMARY KEY (path, direction)
);
```

再開の整合性: SHA は両経路とも streaming で確定するため、再開時は**未処理分だけネットワークし、既処理分はローカル再読込でハッシュを復元**し、最後に必ず期待 SHA と突合する（不一致なら破棄してフル再送＝自己回復）。アップロードは `recordCompletedPart`（完了パートの etag）を再開起点に使う。ダウンロードは **tmp の実サイズ**を再開起点の真実とし（`bytes_done` 列は失敗時に `recordDownloadProgress` で更新する `updated_at` の heartbeat 兼 introspection）、`expected_etag` の照合と最終 SHA 突合で妥当性を担保する。完了・恒久失敗で行は削除し、起動時に消えたファイル/古い行/宙ぶらりんの `upload_id` を best-effort で掃除する（D5）。

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

// M3 サブ D で追加
migrator.registerMigration("v2_transfer_state") { db in
    try db.execute(sql: "CREATE TABLE transfer_state ( ... );")
}

// 将来の変更はここに追加
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

> 以下は概念説明用の簡略例。現行の差分検出は `ChangeDetector`（stat ベースの `preDecision` / `postHash`）が担い、未同期判定は部分インデックス `idx_files_unsynced`（`WHERE last_synced_at IS NULL`）を前提とする。

### 未同期のファイル取得（概念例）

```swift
let unsynced = try FileRecord
    .filter(Column("last_synced_at") == nil)
    .fetchAll(db)
```

### リトライ対象のキュー取得

実装は give-up 上限 `attempts < 5` を先頭に持ち、1 周あたり 20 件取る（`SyncEngine.fetchReadyItems`）。
attempts が 5 に達した行はリトライ対象から外れ、give-up 扱いになる。

```swift
let now = Date().timeIntervalSince1970
let ready = try UploadQueueRecord
    .filter(Column("attempts") < 5)
    .filter(Column("next_retry_at") <= now || Column("next_retry_at") == nil)
    .order(Column("enqueued_at"))
    .limit(20)
    .fetchAll(db)
```

### ハッシュキャッシュのヒット判定（概念例）

ファイルの (size, mtime) が DB と一致したらハッシュ計算スキップ。実装の `ChangeDetector.preDecision`
は 3 値（`.skip` / `.enqueue` / `.verifyHash`）を返し、「size 一致だが mtime 不一致」のときは
`.verifyHash`（SHA 再計算で内容変化を確認）に分岐する:

```swift
let record = try FileRecord.fetchOne(db, key: relativePath)
let needsHash = record == nil || 
                record?.size != currentSize || 
                abs((record?.mtime ?? 0) - currentMtime) > 0.001
```

mtime 比較で 1ms の許容（`abs(diff) < 0.001` を一致扱い）を入れているのは、ファイルシステムの精度差吸収のため。

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
