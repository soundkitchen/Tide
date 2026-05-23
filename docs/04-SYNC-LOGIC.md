# 同期ロジック（M1: 一方向）

## M1 のスコープ

M1 では **ローカル → S3 の一方向** のみを実装する。S3 → ローカルは M2 で実装。

そのため M1 の同期ロジックは「ローカルファイルの変更を検知し、S3 に反映する」だけのシンプルな構造になる。3-way merge は M3 で実装する。

## 起動時のフルスキャン

アプリ起動時、`SyncEngine.triggerFullScan()` で実行される。

```
1. 同期フォルダを再帰的にウォーク（FileManager.enumerator）
   - 除外パターンにマッチするものはスキップ
   - シンボリックリンクは追従しない
   
2. 各ファイルについて:
   a. (path, size, mtime) を DB の files テーブルと比較
   b. DB にエントリがない → 新規ファイル → アップロードキュー追加
   c. DB にエントリあり、size または mtime が違う → SHA-256 再計算
      - ハッシュも違う → 変更あり → アップロードキュー追加
      - ハッシュ同じ → mtime だけ DB 更新（再アップロード不要）
   d. DB にエントリあり、size と mtime が同じ → スキップ（ハッシュ計算もしない）
   
3. DB にあるが実ファイルにないパスを検出
   - これらは削除されたファイル → 削除キュー追加
   
4. キューに溜まったジョブを順次実行
```

### 並列度と順序

- フルスキャンのファイルウォーク: シングルスレッド（メモリ消費抑制）
- ハッシュ計算: 並列度 4（CPU コア数を考慮）
- アップロード: 並列度 5（ネットワーク帯域とのバランス）
- 削除: 並列度 5

順序の保証は不要（並列実行 OK）。

## 通常運転（FSEvents 駆動）

```
[FSEvents イベント発生]
   │
   ▼
[FileWatcher.events ストリーム]
   │
   ▼
[ハードコード除外フィルタ]
   │  .DS_Store, .Trashes, .Spotlight-V100, .fseventsd, Thumbs.db
   │  → 除外対象なら破棄
   ▼
[DebounceQueue（パスごとに 2 秒）]
   │  同じパスのイベントを集約
   ▼
[SyncEngine.handleChange(event)]
   │
   ▼
[操作種別判定]
   │
   ├─ ファイルが存在する（create / modify）
   │     │
   │     ▼
   │   [DB の files テーブル参照]
   │     │
   │     ├─ DB エントリなし → 新規 → ハッシュ計算 → upload キューへ
   │     ├─ size, mtime 一致 → 何もしない
   │     └─ size または mtime 異なる
   │         │
   │         ▼
   │       [SHA-256 再計算]
   │         │
   │         ├─ ハッシュ一致 → DB の mtime のみ更新
   │         └─ ハッシュ異なる → upload キューへ
   │
   └─ ファイルが存在しない（delete）
        │
        ▼
      [DB の files テーブル参照]
        │
        ├─ DB エントリなし → 何もしない（既に削除済み or 元から無視対象）
        └─ DB エントリあり → delete キューへ
```

## アップロード処理の詳細

```swift
func processUpload(_ queueItem: UploadQueueRecord) async throws {
    let path = queueItem.path
    let fullURL = syncRoot.appendingPathComponent(path)
    
    // 1. ファイル読み込み
    let data = try Data(contentsOf: fullURL)
    let size = data.count
    let mtime = try fullURL.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate!
                            .timeIntervalSince1970
    let sha256 = SHA256.hash(data: data).hex
    
    // 2. S3 にアップロード
    let metadata = [
        "sha256": sha256,
        "mtime": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: mtime)),
        "device": deviceId,
        "size": String(size)
    ]
    let s3Key = "files/\(path)"
    let result = try await s3Client.putObject(
        key: s3Key,
        data: data,
        metadata: metadata
    )
    
    // 3. マニフェスト更新（楽観的ロック）
    let shardId = ShardSharding.shardId(for: path)
    try await updateShard(shardId: shardId) { shard in
        shard.files[path] = ManifestFileEntry(
            size: Int64(size),
            mtime: mtime,
            sha256: sha256,
            s3VersionId: result.versionId,
            etag: result.etag,
            deviceId: deviceId,
            uploadedAt: Date()
        )
    }
    
    // 4. ローカル DB 更新（トランザクション）
    try await database.write { db in
        try FileRecord(
            path: path,
            size: Int64(size),
            mtime: mtime,
            sha256: sha256,
            s3VersionId: result.versionId,
            s3Etag: result.etag,
            lastSyncedAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970
        ).save(db)
        
        try UploadQueueRecord
            .filter(Column("path") == path)
            .deleteAll(db)
        
        try SyncLog.insert(db, type: "upload", path: path, message: "Uploaded \(size) bytes")
    }
}
```

### 100MB 超のファイル（M1 では未対応）

```swift
let MAX_SIZE_M1 = 100 * 1024 * 1024  // 100 MiB

if size > MAX_SIZE_M1 {
    // M1 ではスキップしてエラーログだけ残す
    try await database.write { db in
        try UploadQueueRecord
            .filter(Column("path") == path)
            .deleteAll(db)
        try SyncLog.insert(
            db, 
            type: "error", 
            path: path, 
            message: "File too large for M1 (>100MB). Will be handled in M3."
        )
    }
    return
}
```

## マニフェスト更新の実装

楽観的ロックでシャードを更新する関数:

```swift
func updateShard(shardId: String, transform: (inout ManifestShard) -> Void) async throws {
    let maxRetries = 5
    var lastError: Error?
    
    for attempt in 0..<maxRetries {
        do {
            // 1. 現在のシャードを取得
            let (currentShard, currentETag) = try await s3Client.getShardWithETag(shardId) 
                ?? (ManifestShard.empty(id: shardId), nil)
            
            // 2. 変換適用
            var newShard = currentShard
            transform(&newShard)
            newShard.updatedAt = Date()
            
            // 3. 楽観的ロックで PUT
            let newETag = try await s3Client.putShard(
                newShard,
                expectedETag: currentETag  // nil の場合は If-None-Match: * を付ける
            )
            
            // 4. index.json も更新
            try await updateIndex(shardId: shardId, newETag: newETag, count: newShard.files.count)
            
            return  // 成功
            
        } catch let error as S3Error where error.isPreconditionFailed {
            // 412: 他のプロセスが更新した → リトライ
            lastError = error
            try await Task.sleep(nanoseconds: UInt64.random(in: 100_000_000...500_000_000))
            continue
        }
    }
    
    throw lastError ?? SyncError.manifestUpdateFailed
}
```

### シャード削除のケース

ファイル削除でシャードが空になった場合の扱い:

```swift
if newShard.files.isEmpty {
    // S3 からシャードファイルを削除
    try await s3Client.deleteObject(key: ".tide/shards/\(shardId).json")
    
    // index からエントリ削除
    try await updateIndex(removingShardId: shardId)
} else {
    // 通常更新
    try await s3Client.putShard(newShard, expectedETag: currentETag)
    try await updateIndex(shardId: shardId, newETag: newETag, count: newShard.files.count)
}
```

## 削除処理

```swift
func processDelete(_ queueItem: UploadQueueRecord) async throws {
    let path = queueItem.path
    let s3Key = "files/\(path)"
    
    // 1. S3 で delete marker を付ける（versioning 有効なので物理削除されない）
    try await s3Client.deleteObject(key: s3Key)
    
    // 2. マニフェストから削除
    let shardId = ShardSharding.shardId(for: path)
    try await updateShard(shardId: shardId) { shard in
        shard.files.removeValue(forKey: path)
    }
    
    // 3. ローカル DB から削除
    try await database.write { db in
        try FileRecord.deleteOne(db, key: path)
        try UploadQueueRecord
            .filter(Column("path") == path)
            .deleteAll(db)
        try SyncLog.insert(db, type: "delete", path: path, message: "Deleted")
    }
}
```

## リトライ戦略

エラー発生時、指数バックオフでリトライ:

```swift
func computeNextRetryDelay(attempts: Int) -> TimeInterval {
    // 1s, 2s, 4s, 8s, 16s, 32s, 64s, ...
    let base = pow(2.0, Double(attempts))
    // ± 25% のジッタ
    let jitter = Double.random(in: 0.75...1.25)
    let delay = base * jitter
    return min(delay, 300)  // 上限 5 分
}

func handleUploadError(_ item: UploadQueueRecord, error: Error) async throws {
    let newAttempts = item.attempts + 1
    
    if newAttempts >= 5 {
        // 諦める。エラーログに残してキューから削除
        try await database.write { db in
            try UploadQueueRecord.deleteOne(db, key: item.id!)
            try SyncLog.insert(
                db, type: "error", path: item.path,
                message: "Upload failed after 5 attempts: \(error)"
            )
        }
        return
    }
    
    let delay = computeNextRetryDelay(attempts: newAttempts)
    let nextRetry = Date().addingTimeInterval(delay)
    
    try await database.write { db in
        var updated = item
        updated.attempts = newAttempts
        updated.nextRetryAt = nextRetry.timeIntervalSince1970
        updated.lastError = String(describing: error)
        try updated.update(db)
    }
}
```

## 起動時のキュー復旧

アプリ再起動時、前回の未完了キューを復旧:

```swift
func resumeQueue() async throws {
    let pending = try await database.read { db in
        try UploadQueueRecord
            .filter(Column("attempts") < 5)
            .fetchAll(db)
    }
    
    for item in pending {
        await processingQueue.enqueue(item)
    }
}
```

## 除外ルール（M1）

M1 では `.syncignore` 対応はしない。ハードコードの除外のみ:

```swift
struct HardcodedIgnoreRules {
    static let patterns: Set<String> = [
        ".DS_Store",
        "Thumbs.db",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems"
    ]
    
    static let prefixPatterns = [
        ".DocumentRevisions-V100"
    ]
    
    static func shouldIgnore(path: String) -> Bool {
        let components = path.split(separator: "/")
        
        // パス中のどこかに除外対象があれば除外
        for component in components {
            if patterns.contains(String(component)) {
                return true
            }
            for prefix in prefixPatterns {
                if component.hasPrefix(prefix) {
                    return true
                }
            }
        }
        return false
    }
}
```

## エッジケース

### ファイルが読み込み中に削除された

```swift
do {
    let data = try Data(contentsOf: fullURL)
    // ...
} catch CocoaError.fileReadNoSuchFile {
    // 読み込み中に削除された → delete として処理し直す
    try await database.write { db in
        var item = item
        item.operation = "delete"
        try item.update(db)
    }
    return
}
```

### アトミック書き込み（テキストエディタ等）

多くのエディタは「一時ファイル作成 → リネーム」でアトミック書き込みする。これは FSEvents 的には:
- 一時ファイル `foo.txt.swp` の create
- `foo.txt.swp` → `foo.txt` の rename（移動として通知される）

`kFSEventStreamCreateFlagFileEvents` を有効にしていれば、`kFSEventStreamEventFlagItemRenamed` フラグで判別できる。M1 ではシンプルに「rename も create/delete として扱う」で十分。デバウンスにより最終状態だけ拾えればよい。

### ファイル名がプラットフォーム依存

macOS は NFD（分解形式）でファイル名を返す。S3 にはこれをそのまま渡す。NFC（合成形式）に正規化したくなる誘惑があるが、**しない**。ローカルの実態と一致させる方が安全。

ただし、別 OS（Windows / Linux）から見るときに見えにくくなる可能性はある。これは M3 以降で議論。
