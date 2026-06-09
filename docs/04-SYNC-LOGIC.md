# 同期ロジック

> **スコープの現状 (2026-06-05)**:
> - **M1 完了**: ローカル → S3 の一方向アップロード（本書の前半）
> - **M2 完了**: S3 → ローカルのダウンロード、定期ポーリング、リモート削除反映、コンフリクトリネーム（本書末尾「M2 セクション」）
> - **M3 サブ A〜D 実装済み**: 形式的な 3-way merge（サブ C・本書「競合解決」）、マルチパートアップロード / レンジダウンロード再開（サブ A・D）、`.syncignore`（サブ B）、中断・再開（サブ D）。帯域制御（E）は未着手。詳細は `07-M3-IMPLEMENTATION-GUIDE.md`

## M1 のスコープ

M1 では **ローカル → S3 の一方向** のみを実装する。

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

> **実装ノート（2026-06-08・SHA ゲート実装）**: 2.b〜d の変更判定は純粋関数 **`ChangeDetector`**（`Tide/Core/ChangeDetector.swift`、`preDecision`/`postHash` の two-step）に集約し、FSEvents 経路（後述）と共用する。仕様との差分は最適化 1 点のみ: **size 不一致のときは SHA を再計算せず直接アップロードキューへ**（size が違えば sha は一致し得ないため挙動は同義）。「ハッシュ同じ → mtime だけ DB 更新」は **CAS**（`LocalDatabase.refreshMtimeIfShaUnchanged`: 単一 write Tx 内で再フェッチし sha 一致時のみ更新・`lastSyncedAt` は保持）で行い、判定〜書込の間に走った並行 pull の更新（新 sha / versionId）を巻き戻さない。
>
> **不変条件: 「`FileRecord.mtime` = 最後に同期した時点のローカル stat mtime」**。マニフェスト `mtime` は ISO8601 秒精度（fractional なし）なので、これで DB を上書きすると上記 2.d の比較（許容差 0.001s）が常に外れ、無変更ファイルが毎起動再アップロードされる（実際に起きたバグ・2026-06-08 修正。`CLAUDE.md §8` 参照）。pull の内容一致時の DB 最新化（`Downloader.updateDBEntryWithoutWrite`）もローカル stat 実値を記録する。SHA ゲートは、過去に秒精度で汚染された既存 DB も初回スキャンの「hash 1 回 → mtime 修復のみ」で自己回復させる安全網を兼ねる。

### 並列度と順序

- フルスキャンのファイルウォーク: シングルスレッド（メモリ消費抑制）
- ハッシュ計算: 現実装はウォーク内で直列（SHA ゲート含む。遅ければ有界並列化は将来タスク）
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
        
        try UploadQueueRecord                       // L6: path ではなく id 基準（後述）
            .filter(Column("id") == queueItem.id)
            .deleteAll(db)
        
        try SyncLog.insert(db, type: "upload", path: path, message: "Uploaded \(size) bytes")
    }
}
```

### 大きいファイル（M3: マルチパート + 1 ファイル上限）

M1 の 100MiB ハード上限（`maxSizeM1`）は M3 で撤廃した。`Uploader.processUpload` はサイズで経路を分岐する。

- **シングルパート**（`≤ 16 MiB`、`PartPlan.shouldUseMultipart` が false）: O_NOFOLLOW の単一 FD から 1 回読んだバッファでハッシュも本体も賄い（M5: 2 回 open を畳む）、`putObject` で送る。
- **マルチパート**（`> 16 MiB`）: `MultipartUploader` が単一 FD から順次読込しつつ SHA-256 を逐次更新し、読み終えたパートを**有界並列（最大 3）で UploadPart**。アダプティブパートサイズ（`PartPlan`）: 目標パート数 9,000 基準値を `[5MiB, 64MiB]` にクランプ（常駐メモリ抑制）、10,000 パートに収まらない超巨大ファイルのみ必要分まで partSize を上げる（MiB 境界切り上げで `partCount ≤ 10,000`）。瞬断は**パート単位リトライ**で吸収し、恒久失敗は best-effort `abort` → throw（ファイル単位リトライへ）。`UploadId` の永続化・再起動またぎ再開はサブタスク D（別チャンク）。

**1 ファイルあたりのアップロード上限**は `ConfigStore.uploadSizeLimitBytes`（Settings で変更、既定 1GiB、`-1` = 無制限）。上限はアップロード方向のみに適用し、ダウンロード（復元）は常に許可する。上限超過は**黙ってスキップせず** `SyncError.fileTooLarge` を投げ、`SyncEngine.handleProcessingFailure` がリトライせずに `recentErrors` へ明示 + `sync_log` の `error` 記録 + キュー除去する（「このファイルはバックアップされていない」を可視化）。

```swift
let limit = config.uploadSizeLimitBytes   // 既定 1GiB、-1 = 無制限
guard PartPlan.isWithinUploadLimit(size: size, limitBytes: limit) else {
    throw SyncError.fileTooLarge(path: path, size: size)  // → recentErrors に明示、リトライしない
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
            
        } catch let error where error.isPreconditionFailed || error.isConditionalConflict {
            // 412 PreconditionFailed（他プロセスが更新済み）/ 409 ConditionalRequestConflict
            // （同一キーへの並行条件付き PUT 衝突）→ 再取得してリトライ
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
        try UploadQueueRecord                       // L6: path ではなく id 基準（後述）
            .filter(Column("id") == queueItem.id)
            .deleteAll(db)
        try SyncLog.insert(db, type: "delete", path: path, message: "Deleted")
    }
}
```

> **キュー行は id 基準で消す（L6・2026-06-09）**: 上記 4. / 3. の `upload_queue` 削除は、`path` ではなく **処理したこの行 (`queueItem.id`)** を対象にする。アップロード/削除の処理中に同 path へ新イベントが届くと、enqueue 側の `INSERT OR REPLACE`（`UNIQUE(path)`）で**新しい AUTOINCREMENT id の行に置換**される（＝「完全版を上げ直せ」という正当な指示）。完了/失敗処理を `path` 基準で消すとその新行まで巻き込み、ローカル≠DB≠リモートの**無エラー乖離**が次回フルスキャンまで残る。id 基準なら旧行の完了/失敗は新行に触れず、次周回で再処理されて自己修復する。同じ理由で `handleProcessingFailure` の retry 更新・give-up 削除・size-limit 削除もすべて `id` 基準。

> **torn read を“コミット”しない安定化ゲート（L6・A-detect・2026-06-09）**: アップロードは単一 `O_NOFOLLOW` FD から読むが、読込中にローカルが書き換えられると torn（千切れ）な内容を S3 にコミットし得る。**読み終えた後に同 FD を再 `fstat`** し、開始時の (size, mtime) と size 変化 or mtime 前進があれば「不安定」とみなす（純粋関数 `StabilityCheck.isStable`）。シングルパートは上記 2. の `putObject` の**前**に判定し、不安定なら **PUT しない**（現行 S3 オブジェクトを torn で上書きしない）。マルチパートは `completeMultipartUpload` の**前**に判定し、不安定なら **abort +（resume 時）checkpoint クリア**（complete しないので現行版は無傷・新 mtime でフル再開）。いずれも `SyncError.fileChangedDuringUpload` を投げる。加えてマルチパートは **read ループ内で逐次 early-bail**（読了量が開始時 size 超過＝成長／`reader.info()` の mtime 前進＝in-place 書換）し、次パートを PUT する前に throw する＝成長/変化し続ける大ファイルで「満額 PUT → 全 abort」を毎リトライ繰り返す PUT 課金・帯域の浪費を避ける。
>
> 書込が落ち着くまで安定しないファイル（ログ/DB 等）は、`handleProcessingFailure` が `fileChangedDuringUpload` を **give-up カウント（`attempts`）に載せず**、`LocalDatabase.deferUnstableQueueItem` で安定するまで延期する（再検査間隔は保留経過に比例・上限 300s、`enqueuedAt`/`attempts` は保持）。一定時間（30s）安定しなければ「まだバックアップされていない」を `recentErrors`/`sync_log` に **1 回だけ**可視化する（＝torn を出さず、取りこぼしも黙らせない）。

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

## `.syncignore` 除外ルール（M3）

M3 で `<syncRoot>/.syncignore`（gitignore 構文の一般的サブセット）対応を追加した。
詳細な確定仕様は `docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク B と `CLAUDE.md` 第 7 節を参照。要点:

- `HardcodedIgnoreRules`（機密網）は**常に最優先**で効く。`.syncignore` の否定 `!` でも覆せない。
- `.syncignore` のユーザパターンは**新規ファイルにのみ**適用する（gitignore 純正）。
  既に同期済み（`FileRecord.lastSyncedAt != nil`）のファイルは触らない。S3 からも勝手に消さない。
  バックアップから外したい時はローカル削除 → 通常の削除伝播で消す。
- `.syncignore` 自身は同期対象に含める（S3 経由で全デバイス・復旧後にも除外設定が伝わる）。
- **新規バケットのセットアップ時のみ**、`SyncIgnoreMatcher.defaultTemplate`（`node_modules/` 等の再生成可能な開発ジャンク）を `<syncRoot>/.syncignore` に自動生成する（`AppEnvironment.completeSetup`）。ローカルに既にある／リモートにマニフェストがある（既存バケット）場合は作らない。`.git/` は含めない（復旧目的で同期対象のまま）。
- スキップ判定は純粋関数 `IgnoreDecision.shouldSkip(relativePath:isAlreadyTracked:matcher:)` に集約し、
  ローカル列挙（`performFullScan`）/ ローカルイベント（`processEventToQueue`）/ リモート取り込み
  （`reconcileRemoteEntry`）の 3 経路すべてで通す。

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

---

# M2: ダウンロード / 復元 / 定期ポーリング

M2 で **S3 → ローカルの取り込み** が追加された。ローカル → S3（M1）の経路は維持しつつ、`SyncEngine` に **リモート pull ループ** を統合する形で実装している。

## 全体像

```
[起動] / [3 分ごと] / [スリープ復帰] / [ネットワーク復帰]
   │
   ▼
[SyncEngine.triggerRemotePull()]
   │
   ▼
[ManifestReader.read()]
   ├─ index.json を GET（最大 16 MiB に制限）
   ├─ shard_state テーブルの etag キャッシュと突き合わせ
   ├─ 変化したシャードのみ並列 GET（最大 8 並列、各 16 MiB 制限）
   └─ 変化なしシャードのファイルはローカル DB から補完
   │
   ▼
[全リモートファイル × 5 並列で reconcileRemoteEntry]
   │  各 path に対して:
   │  ├─ PathValidator で path / shardId を検証（攻撃面の遮断）
   │  ├─ ローカル無し → ダウンロード
   │  ├─ ローカルあり / SHA 一致 → スキップ（DB を最新化）
   │  ├─ ローカルあり / SHA != remote / DB と一致 → ローカル未編集 → ダウンロード（上書き）
   │  └─ ローカルあり / SHA != remote / DB とも違う → コンフリクト
   │       └─ Downloader.renameLocalForConflict → リモートをダウンロード
   ▼
[リモート削除の反映]
   │  「更新があったシャード」に属していたが remoteMap にない path を抽出
   │  各 path に対して Downloader.applyRemoteDeletion
   │  └─ ローカル SHA が DB 記録と一致するときのみ削除（触られていれば残す）
   ▼
[lastRemoteCheckedAt 更新]
```

## トリガー

`SyncEngine.start()` で 3 つのオブザーバを起動する:

1. **periodic poll**: `ConfigStore.pollingIntervalSeconds` で定期実行（既定 180 秒、最小 30 秒で clamp）
2. **wake 復帰**: `NSWorkspace.didWakeNotification` を購読
3. **network 復帰**: `NWPathMonitor` で `unsatisfied → satisfied` を検出

これら 3 つに加え、起動時 pull（`start()`）とメニューの「S3 から取得」も含め、**すべて `triggerRemotePull(reason:)` の単一ゲートを通り、`isRemotePulling` フラグで直列化される**（並行 pull を構造的に禁止＝同一ファイルの並行ダウンロードによる共有 tmp 破損を防ぐ）。`reason` はログ用で、ゲート通過後にのみ出力する。

pull 進行中の再入は原則ドロップだが、**手動（`reason == .manual`）だけは pending 化し、現 pull 終了後にもう 1 周する**（coalescing・PR #9 レビュー ④。長い復元 pull 中の押下でも「最新を取得したい」意図が確実に反映される。reason は `.manualCoalesced`＝ログには `manual-coalesced`）。`reason` は coalescing の分岐条件を持ったため `SyncEngine.PullReason` enum（ログは rawValue）。poll/wake/network は次の周期が必ず来るので従来どおりドロップ。coalesced ラウンドは `running && !Task.isCancelled` も条件に含み、**`stop()` 後や呼び元タスク cancel 後に新ラウンドを開始しない**（in-flight の 1 周は走り切る）。`isRemotePulling` は `@Observable` な公開状態で、メニューバーの「Pull from S3」ボタンが pull 中はスピナー + 「Pulling…」表示に切り替わる（ボタンは enabled のまま＝押下が coalescing の入口）。

## ManifestReader: 変更差分の効率取得

`Tide/S3/ManifestReader.swift` が中心。

```swift
struct ReadResult {
    var files: [String: ManifestFileEntry]  // 現在のリモート全ファイル
    var updatedShards: Set<String>          // 今回新規 GET したシャード
    var removedShards: Set<String>          // index から消えたシャード（=配下削除）
}
```

- `index.json` だけ毎回取得（軽量）
- 各シャードの etag を `shard_state` テーブルにキャッシュ
- 差分のあるシャードだけ並列 GET
- **変化なしシャードのファイル**はローカル DB の `files` テーブルから「最後に同期した状態」として補完する。シャード自体は再取得しない。

## Downloader: 単一ファイル取得

`Tide/S3/Downloader.swift` の `download(relativePath:entry:)`:

```
1. PathValidator.resolveForWrite で path 検証 + syncRoot 配下確認（祖先ディレクトリの symlink 経由のルート脱出も拒否 / F2）
2. 既存ローカルファイル（最終コンポーネント）がシンボリックリンクなら拒否（実体書換防止）
3. ローカル SHA == manifest SHA ならスキップ（DB のみ最新化）
4. 中断・再開（サブ D-D3）: 決定的 tmp（dl-<sha(path)>.part）を使う。transfer_state の download 行があり
   expected_etag == entry.etag かつ tmp が 0 < size < entry.size なら、その既存プレフィクスを読み直して
   hasher に前置きし resumeFrom = size とする。無効（行なし / etag 不一致 / サイズ不整合）なら tmp を作り直し begin
5. streamObject(rangeStart:)（resumeFrom > 0 なら Range: bytes=resumeFrom-）で tmp へ追記しつつ SHA-256 を逐次更新。
   sink で受信累積長を entry.size と突合し、超過は tooLarge で破棄（M7 の DoS ガード）
6. SHA-256 検証（manifest と byte 不一致なら tmp を破棄し行をクリアして abort＝壊れた内容を再開し続けない）
7. mtime をマニフェストの値で復元
8. 親ディレクトリ作成（SHA 検証後＝不一致で捨てるとき空ディレクトリの litter を残さない）
9. 既存ファイルがあれば removeItem → moveItem で atomic に置換
   （replaceItemAt は .sb-* 中間ファイルを作って FSEvents を汚すので使わない）
10. transfer_state の行をクリア + DB を更新 + sync_log 記録
```

> ストリーミング途中のネットワーク失敗は **部分 tmp と transfer_state 行を保持**し、次回 pull で同じ tmp を `Range: bytes=N-` で再開する（N は実際の tmp サイズ＝プロセス kill 後も確実）。さらに **当該シャードの `shard_state` を sentinel 化（空 etag・`LocalDatabase.invalidateShardCache`）** する。`ManifestReader` は fetch 時点（DL 完了前）でシャードを「取得済み」記録するため、これを欠くと同一セッション中の poll/wake/network-up pull が当該シャードをキャッシュ済み扱いし、再開経路に到達しない（PR #9 レビュー ②）。再 arm はこの resumable 失敗のみで、**破棄系（SHA 不一致 / 実サイズ不一致 / サイズ超過 / 404）は再 arm しない**（決定的に再失敗するためリトライストームを避け、リモートのシャード etag 変化による自然回復に委ねる）。実 DB + フェイク `RangedDownloadClient` での結合的ユニットテストは `DownloaderTests`。
>
> 起動時の掃除（`SyncEngine.pruneOrphanTransfers`）も同じ sentinel 化を行う: resumable な download 行（tmp あり・新しい）は行と tmp を温存して invalidate のみ（再 arm）、clear する行（tmp 消失 / 7 日超 stale）も**行を落とす前に**必ず invalidate する（これを欠くと FileRecord 無し + 実 etag のままで当該ファイルが永久に再 DL されない。受け入れテスト §6-2 で発見・2026-06-07 修正）。invalidate に失敗したら行を消さず次回起動の prune に委ねる（自己回復）。prune の「分岐 → 実 I/O」配線は `TransferPruneTests`（実 DB）で回帰固定。

## 競合解決（3-way merge）

M3 サブ C で **ベース / ローカル / リモートの 3 SHA による 3-way merge として形式化**した（2026-06-04）。判定は純粋関数 `ThreeWayMerge.decide(base:local:remote:) -> MergeDecision` に集約され、`SyncEngine.reconcileRemoteEntry`（pull 側）と `Downloader.applyRemoteDeletion`（削除側）の両方がこれを通す。**ベースは「最後にローカル DB へ記録した SHA」(`FileRecord.sha256`)** で、マニフェスト schema は拡張していない。挙動は下表（旧 M2 ルール）と一致し（1 点だけ後述の unreadable の扱いを安全側に厳格化）、全分岐は `ThreeWayMergeTests` で網羅する。

ローカル状態は `LocalState`（`.absent` / `.unreadable` / `.present(sha)`）で表す。下表の「あり」は SHA が取れた `.present`。

| ローカル状態 | リモート状態 | 動作 | `MergeDecision` |
|---|---|---|---|
| 無 | あり | ダウンロード | `.download` |
| あり / SHA = remote | あり | スキップ + DB 最新化（mtime は**ローカル stat 実値**を記録。マニフェストの秒精度値で上書きするとフルスキャンの mtime 比較が外れ毎起動再アップロードになる） | `.localMatchesRemote` |
| あり / SHA != remote / SHA = DB（前回 sync 時） | あり | ダウンロード（remote が新しいと判断） | `.download` |
| あり / SHA != remote / SHA != DB（or DB 記録なし） | あり | **コンフリクト**: `<stem> (local copy YYYY-MM-DD HH-MM-SS).<ext>` にリネーム → remote をダウンロード。リネーム後のファイルは FSEvents 経由で M1 アップロードキューに乗る | `.conflictThenDownload` |
| あり / SHA = DB | 無 | ローカル削除（リモート削除の反映） | `.deleteLocal` |
| あり / SHA != DB（or DB 記録なし） | 無 | **温存** + `sync_log` に warning（ユーザがローカルで編集中とみなす） | `.keepLocalRemoteDeleted` |
| 無 | 無 | 何もしない | `.noop` |

**`.unreadable`（ファイルは在るが SHA を計算できない＝権限/I-O エラー等）の扱い**: 乖離の有無を確認できないので**データ安全側へ倒す**。リモートあり（pull）→ 無確認で上書きせず `.conflictThenDownload`（ローカルをコンフリクトコピーへ退避してから取得）／リモート無（削除）→ `.keepLocalRemoteDeleted`（温存）。旧 M2 は pull 側のハッシュ失敗を無確認 download に倒していた（＝乖離ローカルを失い得た）が、サブ C で `LocalState` に持ち上げてこの 1 点だけ厳格化した（PR #3 レビュー指摘 1）。

「両方が同じ方向に変化」（ベースから local も remote も同一内容へ）は `local == remote` なので `.localMatchesRemote`（fast-forward）に入る。リネーム規則は `ConflictNamer.localCopyRelativePath(for:at:)`。dotfile / 拡張子なしも対応。

> **既知の制限（アップロード側の last-writer-wins）**: 競合検出は現状 **pull/削除側のみ**。同一ベースから 2 台が編集すると後勝ちでマニフェストが上書きされ、先に上げた側は次回 pull で「local == base＝未編集」と判定して相手版を取り込み、自分のローカル編集がワーキングコピーから消える（S3 のバージョン履歴には残る）。アップロード直前にも `ThreeWayMerge` を適用する対称化は将来サブタスク（`07-M3-IMPLEMENTATION-GUIDE.md` 参照）。

## セキュリティゲート

- マニフェスト由来の `relativePath` / `shardId` は **すべて** `PathValidator` を通す（`..` / 絶対パス / NUL / バックスラッシュ等を拒否し、解決後 URL が syncRoot 配下にあることまで確認）
- マニフェスト系の `getObject` は `maxBytes` 16 MiB（OOM 自己防衛）。通常ファイルの DL は `streamObject` でチャンク・ストリーミング書込（メモリ有界）。旧 200MiB インメモリ cap は撤廃。**復元の DoS ガード（M7）は `Downloader` 側**: streaming の sink で受信累積長を**マニフェストの真実サイズ `entry.size`** と突合し、超過は破棄して仕切り直す（巨大本文によるローカルディスク枯渇を復元経路でも防ぐ＝M4 を復元でも維持）。アップロード上限とは別物（復元方向はユーザ上限を適用しない）
- フルスキャンの enumerator はシンボリックリンクを skipDescendants して追従しない
- Downloader の書き込み先（最終コンポーネント）がシンボリックリンクなら拒否
- 書込・削除経路（Downloader の `download` / `applyRemoteDeletion` / `renameLocalForConflict`）は `PathValidator.resolveForWrite` を通し、**祖先ディレクトリの symlink 経由のルート脱出**も拒否する（F2 / M6）
- **Uploader は `O_NOFOLLOW` の単一 FD で open し、最終コンポーネントが symlink なら ELOOP で拒否してキューから外す。ハッシュ計算と本体読込/パート送信は同一 FD から行うので、「ハッシュ用 open → 本体用 open」の 2 回 open に存在した TOCTOU 窓を解消した（M5 / F3 / L9）**。祖先 symlink は対象外で `resolveSafely` の字句検証とスキャンの skip に委ねる

詳細は `security/critical.md` の C1 / C2、`security/medium.md` の M3 / M4 / M5 / M6、`security/low.md` の L9 を参照。
