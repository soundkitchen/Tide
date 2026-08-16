# 同期ロジック — folderSync（FSEvents）世代の記録

> **folderSync 世代の歴史的記録（削除予約）**。v0.3.0（2026-08-17）でユーザー到達不能になった
> デッドコード仕様。コード本体（`SyncEngine` / `FileWatcher` / `DebounceQueue` / `Uploader` /
> `Downloader` / `ManifestReader` 等）はリポジトリに温存され `make test` が回帰網
> （`ScanEventWiringTests` / `ReconcileWiringTests` / `RemoteDeletionTests` / `DownloaderTests` /
> `TransferPruneTests` 等）ごと検証し続けており、本書はその仕様根拠として維持する。
> **FSEvents コードの物理撤去（FP-only 無事故実績 + 2 台 soak 後ゲート）と同時に本ファイルごと
> 削除する**。folderSync へ戻す手順は `docs/09`「revert 復帰ランブック」（クリーン再セットアップのみ・
> 増分復帰は資産消滅により不能）。現行（fpOnly）の同期ロジックは
> [`04-SYNC-LOGIC.md`](04-SYNC-LOGIC.md) を参照。
>
> 注: 本書前半（M1）の擬似コードには当時のスケッチが残っている箇所がある（object metadata の
> sha256、`HardcodedIgnoreRules` のシグネチャ等）。各所の注記と実コードを正とする。
> パス表記は M5 Phase 1 の `TideCore` 分離後の物理位置に更新済み。

## folderSync の全体像

ローカル実体フォルダ（syncRoot・旧 `~/Tide`）を持ち、ローカル → S3 は
「FSEvents + フルスキャン → アップロードキュー（DB 永続）→ `Uploader`」、S3 → ローカルは
「定期 pull → `ManifestReader` 差分取得 → `reconcileRemoteEntry`（3-way）→ `Downloader`」で回す。
状態管理はローカル DB（`docs/03-LOCAL-DATABASE.md`）。

## 起動時のフルスキャン

アプリ起動時、`SyncEngine.triggerFullScan()` で実行される。

```
1. 同期フォルダを再帰的にウォーク（walkSyncTree・再帰下降）
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

> **実装ノート（2026-06-08・SHA ゲート実装）**: 2.b〜d の変更判定は純粋関数 **`ChangeDetector`**
> （`TideCore/Core/ChangeDetector.swift`、`preDecision`/`postHash` の two-step）に集約し、
> FSEvents 経路（後述）と共用する。仕様との差分は最適化 1 点のみ: **size 不一致のときは SHA を
> 再計算せず直接アップロードキューへ**（size が違えば sha は一致し得ないため挙動は同義）。
> 「ハッシュ同じ → mtime だけ DB 更新」は **CAS**（`LocalDatabase.refreshMtimeIfShaUnchanged`:
> 単一 write Tx 内で再フェッチし sha 一致時のみ更新・`lastSyncedAt` は保持）で行い、判定〜書込の
> 間に走った並行 pull の更新（新 sha / versionId）を巻き戻さない。
>
> **不変条件: 「`FileRecord.mtime` = 最後に同期した時点のローカル stat mtime」**。マニフェスト
> `mtime` は ISO8601 秒精度（fractional なし）なので、これで DB を上書きすると上記 2.d の比較
> （許容差 0.001s）が常に外れ、無変更ファイルが毎起動再アップロードされる（実際に起きたバグ・
> 2026-06-08 修正。`docs/09-DEFERRED.md` 参照）。pull の内容一致時の DB 最新化
> （`Downloader.markSynced`）もローカル stat 実値を記録する。SHA ゲートは、過去に秒精度で汚染された
> 既存 DB も初回スキャンの「hash 1 回 → mtime 修復のみ」で自己回復させる安全網を兼ねる。

### 並列度と順序

- フルスキャンのファイルウォーク: シングルスレッド（メモリ消費抑制）
- ハッシュ計算: ウォーク内で直列（SHA ゲート含む）
- アップロード: 並列度 5 / 削除: 並列度 5
- 順序の保証は不要（並列実行 OK）。ただし種別変化対策としてスキャンは
  **削除検出 → upload 候補の順で enqueue** する（後述 Issue #52）

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
   │     ├─ path が今ディレクトリ（種別変化の検出 / Issue #52）
   │     │     ├─ DB エントリなし → 何もしない（通常のディレクトリイベント）
   │     │     └─ DB エントリあり → 追跡中ファイルがディレクトリへ置換された
   │     │        → 旧ファイルの delete キューへ（.replace ＝誤分類済み upload 行を潰す）
   │     │        → フルスキャン発火（`mv 既存dir path` の置換は子のイベントが出ないため配下はスキャンで拾う）
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
    // ※ 実装は object metadata に sha256 を載せない（CreateMultipartUpload 時点で
    //    未確定なため。整合性の真実は ManifestFileEntry.sha256 に置く）。metadata は mtime/device/size のみ
    //    （この metadata 規約自体も folderSync 世代のもの。fpOnly の書き手は metadata を付けない）。
    let metadata = [
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

    // 3. マニフェスト更新（楽観的ロック・実体は ManifestUpdater.updateFileEntry =
    //    docs/04「マニフェスト更新の実装」）
    let shardId = ShardSharding.shardId(for: path)
    try await updateShard(shardId: shardId) { shard in
        shard.files[path] = ManifestFileEntry(...)
    }

    // 4. ローカル DB 更新（トランザクション）
    try await database.write { db in
        try FileRecord(...).save(db)

        try UploadQueueRecord                       // L6: path ではなく id 基準（後述）
            .filter(Column("id") == queueItem.id)
            .deleteAll(db)

        try SyncLog.insert(db, type: "upload", path: path, message: "Uploaded \(size) bytes")
    }
}
```

大きいファイルの経路分岐（`PartPlan` / `MultipartUploader`）は共有ロジックとして
`docs/04`「大きいファイル」を参照。folderSync 固有分は以下:

- **`UploadId` の永続化・再起動またぎ再開**（サブタスク D）: checkpoint を `transfer_state` に持つ。
  **再開時の stale UploadId**（前回 complete 済みでクラッシュ / 7 日ライフサイクル失効）は
  `NoSuchUpload` で空振りするので、complete 時は `headObject` で本体を確認し存在 & サイズ一致なら
  identity を回収して成功扱い、回収不能なら checkpoint を破棄してフル再開に委ねる
  （Issue #33。`docs/09` 据え置き (a) / `docs/08`）。
- **上限超過の可視化**: `SyncError.fileTooLarge` を `SyncEngine.handleProcessingFailure` が
  リトライせずに `recentIssues` へ明示 + `sync_log` の `error` 記録 + キュー除去する
  （「このファイルはバックアップされていない」を可視化）。

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

> **キュー行は id 基準で消す（L6・2026-06-09）**: 上記 4. / 3. の `upload_queue` 削除は、`path`
> ではなく **処理したこの行 (`queueItem.id`)** を対象にする。アップロード / 削除の処理中に同 path へ
> 新イベントが届くと、enqueue 側の `INSERT OR REPLACE`（`UNIQUE(path)`）で**新しい AUTOINCREMENT id
> の行に置換**される（＝「完全版を上げ直せ」という正当な指示）。完了 / 失敗処理を `path` 基準で消すと
> その新行まで巻き込み、ローカル≠DB≠リモートの**無エラー乖離**が次回フルスキャンまで残る。id 基準
> なら旧行の完了 / 失敗は新行に触れず、次周回で再処理されて自己修復する。同じ理由で
> `handleProcessingFailure` の retry 更新・give-up 削除・size-limit 削除もすべて `id` 基準。

> **torn read を"コミット"しない安定化ゲート（L6・A-detect・2026-06-09）**: アップロードは単一
> `O_NOFOLLOW` FD から読むが、読込中にローカルが書き換えられると torn（千切れ）な内容を S3 に
> コミットし得る。**読み終えた後に同 FD を再 `fstat`** し、開始時の (size, mtime) と size 変化 or
> mtime 前進があれば「不安定」とみなす（純粋関数 `StabilityCheck.isStable`）。シングルパートは
> `putObject` の**前**に判定し、不安定なら **PUT しない**。マルチパートは
> `completeMultipartUpload` の**前**に判定し、不安定なら **abort +（resume 時）checkpoint クリア**。
> いずれも `SyncError.fileChangedDuringUpload` を投げる。加えてマルチパートは **read ループ内で
> 逐次 early-bail**（読了量が開始時 size 超過＝成長 / `reader.info()` の mtime 前進＝in-place 書換）し、
> 成長し続ける大ファイルで「満額 PUT → 全 abort」を毎リトライ繰り返す浪費を避ける。
>
> 書込が落ち着くまで安定しないファイル（ログ / DB 等）は、`handleProcessingFailure` が
> `fileChangedDuringUpload` を **give-up カウント（`attempts`）に載せず**、
> `LocalDatabase.deferUnstableQueueItem` で安定するまで延期する（再検査間隔は保留経過に比例・
> 上限 300s）。一定時間（30s）安定しなければ「まだバックアップされていない」を
> `recentIssues`/`sync_log` に **1 回だけ**可視化する。

## リトライ戦略

エラー発生時、指数バックオフでリトライ（give-up 上限 5 回・±25% ジッタ・上限 5 分）。give-up 時は
エラーログに残してキューから削除する。`attempts` / `nextRetryAt` / `lastError` は
`upload_queue` 行に永続する。

## 起動時のキュー復旧

アプリ再起動時、`attempts < 5` の未完了キュー行を読み直して処理キューへ再投入する。

## 除外ルールの folderSync 適用点

判定関数群（`HardcodedIgnoreRules` / `IgnoreDecision.shouldSkip` / `LayeredSyncIgnore`）は
共有ロジック = `docs/04`「除外ルール」が正。folderSync 固有分:

- 適用点は **3 経路**: ローカル列挙（`performFullScan`）/ ローカルイベント
  （`processEventToQueue`）/ リモート取り込み（`reconcileRemoteEntry`）。
- 層辞書の構築はフルスキャンの走査副産物 + ローカル変更のインプレース patch（#64・
  `docs/08`「フルスキャンの単一走査化」）。
- **旧 seed**: 新規バケットのセットアップ時に `<syncRoot>/.syncignore` へテンプレートを自動生成
  していた（`AppEnvironment.completeSetup`）。#97 で **S3 直書き**（`files/.syncignore` PUT）へ
  置換済み = 現行仕様は `docs/04`。

## エッジケース

### ファイルが読み込み中に削除された

読み込みの `fileReadNoSuchFile` を捕捉し、キュー行の `operation` を `delete` に書き換えて
削除として処理し直す。

### ファイルが同名ディレクトリへ置換された（種別変化 / Issue #52）

`rm x.txt && mkdir x.txt && echo hi > x.txt/inner.txt` のような置換は、放置すると
「イベントが置換後のディレクトリを upload に誤分類 → read が EISDIR で 5 回 give-up →
旧ファイルの S3 delete 未発行 → マニフェストに `x.txt`（ファイル）と `x.txt/inner.txt` が両立 →
pull 側がディレクトリを `(local copy …)` へ退避してファイルを復元 → 配下の DL が
『親名がファイルで塞がっている』（POSIX 17）で毎 pull 失敗」という復元不能ループになる。
三層で防ぐ（2026-07-04）:

1. **FileWatcher はディレクトリイベントを落とさない**。rm + mkdir が latency 窓内で合流すると
   FSEvents はフラグを OR 合成する（ItemIsFile|ItemIsDir が両立し得る）ため、watcher で IsDir を
   弾くと検出が timing 依存になる。種別判定は `processEventToQueue` の実 stat に委ねる
   （symlink イベントの skip は従来どおり）。
2. **イベント分類で種別変化を検出**（`processEventToQueue`）: path が今ディレクトリなら通常の
   ファイル処理に進ませない。追跡中（`FileRecord` あり）なら旧ファイルの delete を
   `.replace` で enqueue（誤分類済みの upload 行も潰す）→ フルスキャンを発火して配下を拾う。
   未追跡なら no-op。**同 path の delete 行が既にあれば再入 no-op**
   （S3 障害中の dir イベント再着火が `.replace` で attempts を毎回リセットし、バックオフ /
   give-up を無効化するのを防ぐ。PR #53 レビュー #7。`triggerFullScan` 自体も実行中の再要求を
   pending に coalesce する）。
3. **Uploader の防衛**: `processUpload` は「path がもはや通常ファイルを指せない」open 失敗＝
   **ENOENT（削除）/ EISDIR（ディレクトリ化・`NoFollowFileReader` init の fstat が `.isDirectory`
   として先に判別）/ ENOTDIR（祖先のファイル化）** をまとめて **delete へ変換**する
   （スキャン enqueue 済み行・既存の stale 行の救済。ENOTDIR は PR #53 レビュー #5）。

**鏡像 = ディレクトリ → 同名ファイル置換**（PR #53 レビュー #3）も同経路で検出する:
path が今 regular file で DB に `path/` 配下の追跡行が残っていれば、子孫の delete を
enqueue してから通常の upload 処理へ進む（`enqueueDescendantDeletes` = PK の範囲比較
`>= "p/" AND < "p0"` で配下を列挙。**既に delete 行がある子孫はスキップ** = 親分岐の
再入ガードと同型）。`mv x.dir /outside && cp f x.dir` は子のイベントが出ないため、放置すると
マニフェストに「x.dir（ファイル）+ x.dir/…（配下）」の鏡像不整合が残り、ピア側は子 DL の
ENOTDIR 失敗が恒久化する。

付随ガード: イベント処理の stat 失敗から delete へのフォールバックは**追跡中パスに限定**する
（一過性ディレクトリ等で、未 pull のリモート追跡ファイルを消し得る無条件 delete を発行しない。
PR #53 レビュー #1）。フルスキャンは **削除検出 → upload 候補の順で enqueue** する
（PR #53 レビュー #6）。pull 側もローカル適用のブロック失敗でシャードキャッシュを再 arm し、
置換の伝播窓で 2 台目が取り残されないようにする（下記 Downloader 節）。
配線テストは `ScanEventWiringTests` / `UploaderTypeChangeTests` / `NoFollowFileReaderTests` /
`DownloaderTests`。

> 参考: FP 経路では item identifier の kind 織り込み（`f:`/`d:`）でこの問題クラス自体が
> 構造的に存在しない（`docs/04`「種別変化」）。

### アトミック書き込み（テキストエディタ等）

多くのエディタは「一時ファイル作成 → リネーム」でアトミック書き込みする。
`kFSEventStreamCreateFlagFileEvents` 有効時は `ItemRenamed` フラグで判別できるが、実装は
「rename も create/delete として扱う」で十分（デバウンスにより最終状態だけ拾えればよい）。

---

# M2: ダウンロード / 復元 / 定期ポーリング

M2 で **S3 → ローカルの取り込み** が追加された。ローカル → S3（M1）の経路は維持しつつ、
`SyncEngine` に **リモート pull ループ** を統合する形で実装している。

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
   │  ├─ stat ゲート: ローカル stat == DB かつ DB がリモートを反映（sha/etag/versionId 一致）
   │  │    → 完全スキップ（hash も DB write もしない・steady-state の大半／ChangeDetector.reconcileIsNoop）
   │  ├─ ローカル無し / 未追跡 or SHA != remote → ダウンロード
   │  ├─ ローカル無し / SHA = DB = remote → 取得しない（ローカル削除の伝播待ち・#68）
   │  ├─ ローカルあり / SHA 一致 → markSynced（DB メタデータのみ最新化）
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

判定表（3-way merge）は共有純粋ロジックとして `docs/04`「競合解決」を参照。上図の
`reconcileRemoteEntry`（pull 側）と `applyRemoteDeletion`（削除側）が
`ThreeWayMerge.decide(base:local:remote:)` の folderSync 世代の呼び出し元だった。

> **実装ノート（2026-06-16・pull コスト削減＝M4 perf）**: 未変化シャードのファイルは entry が
> **ローカル DB から再合成**されるため、steady-state では「ローカル == DB == リモート」なのに
> 毎 pull で全ファイルを 2 回ハッシュ＋全行 DB write していた。これを `reconcileRemoteEntry` 入口の
> **stat ゲート**で解消した: 純粋関数 **`ChangeDetector.reconcileIsNoop`**（`preDecision == .skip`＝
> ローカル stat が DB の size/mtime と一致、かつ DB が entry を sha/etag/versionId そのまま反映）が
> 真なら**証明可能な no-op**としてスキップ。ゲートを抜けた `.localMatchesRemote` は専用
> `Downloader.markSynced` で DB を最新化。残るハッシュは `Task.detached(priority:.utility)` で
> off-main 化。詳細は `docs/08`「reconcile 入口の stat ゲート」。

## トリガー

`SyncEngine.start()` で 3 つのオブザーバを起動する:

1. **periodic poll**: `ConfigStore.pollingIntervalSeconds` で定期実行（既定 180 秒、最小 30 秒で clamp）
2. **wake 復帰**: `NSWorkspace.didWakeNotification` を購読
3. **network 復帰**: `NWPathMonitor` で `unsatisfied → satisfied` を検出

これら 3 つに加え、起動時 pull と手動「S3 から取得」も含め、**すべて `triggerRemotePull(reason:)` の
単一ゲート（`RemoteOpGate`）を通って直列化される**（並行 pull を構造的に禁止＝同一ファイルの
並行ダウンロードによる共有 tmp 破損を防ぐ）。

**このゲートは復元（`SyncEngine.restore`）とも共有する**（#34 / D5）。pull は `tryAcquire`
（busy ならドロップ）、復元は `acquire`（FIFO 待機）で取得するので、復元の atomic move と pull の
reconcile / 削除反映が同一 path に同時に触れる窓が構造的に閉じる。`isRemotePulling` は UI 表示専用。
詳細は `docs/08`「リモート pull の単一ゲート化」。

pull 進行中の再入は原則ドロップだが、**手動（`reason == .manual`）だけは pending 化し、現 pull
終了後にもう 1 周する**（coalescing・PR #9 レビュー ④）。coalesced ラウンドは
`running && !Task.isCancelled` も条件に含み、`stop()` 後や呼び元タスク cancel 後に新ラウンドを
開始しない。poll/wake/network は次の周期が必ず来るので従来どおりドロップ。

## ManifestReader: 変更差分の効率取得

`TideCore/S3/ManifestReader.swift` が中心（fpOnly では未使用 — FP は DB 非接触の
`ManifestSnapshotLoader` を使う）。

- `index.json` だけ毎回取得（軽量）
- 各シャードの etag を `shard_state` テーブルにキャッシュし、差分のあるシャードだけ並列 GET
- **変化なしシャードのファイル**はローカル DB の `files` テーブルから「最後に同期した状態」として
  補完する。シャード自体は再取得しない。

## Downloader: 単一ファイル取得

`TideCore/S3/Downloader.swift` の `download(relativePath:entry:)`:

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
9. DL 先が転送中にディレクトリ化していたら中断（-16。removeItem は再帰削除なので置換後の
   新ディレクトリのツリーを競合退避なしに消してしまう。PR #53 レビュー #8）。そうでなければ
   既存ファイルを removeItem → moveItem で atomic に置換
   （replaceItemAt は .sb-* 中間ファイルを作って FSEvents を汚すので使わない）
   ※ 8–9 のローカル適用のブロック失敗（下記注記）は shard_state を再 arm してから tmp と行を
   破棄し、次回 pull に再試行させる（Issue #52）
10. transfer_state の行をクリア + DB を更新 + sync_log 記録
```

> ストリーミング途中のネットワーク失敗は **部分 tmp と transfer_state 行を保持**し、次回 pull で
> 同じ tmp を `Range: bytes=N-` で再開する。さらに **当該シャードの `shard_state` を sentinel 化
> （空 etag・`LocalDatabase.invalidateShardCache`）** する。`ManifestReader` は fetch 時点で
> シャードを「取得済み」記録するため、これを欠くと同一セッション中の pull が当該シャードを
> キャッシュ済み扱いし、再開経路に到達しない（PR #9 レビュー ②）。**破棄系のうち SHA 不一致 /
> 実サイズ不一致 / サイズ超過 / 404 は再 arm しない**（決定的に再失敗するためリトライストームを
> 避け、リモートのシャード etag 変化による自然回復に委ねる）。例外は**ローカル適用（親ディレクトリ
> 作成 → move）の「種別置換ブロック」失敗**（Issue #52・2026-07-04）: 種別置換の伝播窓では
> 決定的に失敗するが、塞ぐ旧エントリは後続 pull の削除反映 / 競合退避で除かれて**その後の再試行は
> 成功する**ので再 arm する（再 arm を欠くと、`FileRecord` の無い端末＝初回取得側では DB 再合成にも
> 乗らず、エラーの無いまま恒久的に取り残される）。再 arm するエラーは
> `Downloader.isBlockedByPathTypeChange`＝**POSIX EEXIST/ENOTDIR・Cocoa 516・自ドメイン -16 に
> 限定**し、EACCES/ENOSPC 等の非自己回復失敗は従来どおり行/tmp 保持のまま伝播する（無差別再 arm は
> バックオフ機構の無い pull 側で毎 pull フル再 DL を無期限化する。PR #53 レビュー #4）。順序は
> [prune 順序] と同じ **invalidate 成功 → 行/tmp 破棄**（逆順だと invalidate 失敗 / 直後クラッシュで
> 「行なし + 実 etag」が残り沈黙恒久停止が再発。PR #53 レビュー #2）。結合的ユニットテストは
> `DownloaderTests`。
>
> 起動時の掃除（`SyncEngine.pruneOrphanTransfers`）も同じ sentinel 化を行う: resumable な
> download 行（tmp あり・新しい）は行と tmp を温存して invalidate のみ（再 arm）、clear する行
> （tmp 消失 / 7 日超 stale）も**行を落とす前に**必ず invalidate する（これを欠くと当該ファイルが
> 永久に再 DL されない。受け入れテスト §6-2 で発見・2026-06-07 修正）。invalidate に失敗したら
> 行を消さず次回起動の prune に委ねる（自己回復）。prune の「分岐 → 実 I/O」配線は
> `TransferPruneTests`（実 DB）で回帰固定。

## ローカル削除の伝播（`.awaitLocalDeletePropagation`・Issue #68 / #69）

fpOnly ではローカル削除が `deleteItem` コールバックで同期的に伝播するため、この pull レース自体が
存在しない。以下は folderSync 世代の配線記録（判定表の該当行は `docs/04`「競合解決」）。

**Issue #68（2026-07-18）**: 追跡済みファイルをローカルで削除した直後、その削除がマニフェストへ
伝播する**前に**定期 pull が走ると、旧実装は「ローカル欠落 / リモートあり」を無条件 `.download` に
倒していたためファイルを再ダウンロードして**復活**させていた。修正では
`local == .absent && remote != nil` を base で分岐する — **`base == remote`（前回同期からリモート
不変・ローカルだけ欠落）は「削除の伝播待ち」として取得しない**（`.awaitLocalDeletePropagation`。
pull 側 `reconcileRemoteEntry` では info ログのみの no-op）。`base == nil`（未追跡＝クリーン
インストール復旧・再セットアップ）と `base != remote`（削除後にリモートが変化＝リモート勝ち）は
従来どおり `.download`。オフライン中 / アプリ停止中のローカル削除は起動時フルスキャンが削除検出を
担うため取りこぼしは生じない。**FileRecord は温存する** — scan の削除検出が record vs 実ファイルの
突合である以上、record を消すとフルスキャンでも削除を検出できなくなるため。

**Issue #69（2026-07-18）**: 再セットアップ直後の採用未了ウィンドウ（base 自体がまだ無い）は —
event `.deleted` は record 不在でも「直近 pull のリモート既知集合（`SyncEngine.remoteKnownPaths`・
シャード単位マージ）掲載 ∧ ignore 非該当」なら delete を enqueue し（`shouldPropagateDeletion`）、
pull 側は「record 無し × ローカル不在 × 同 path の delete 行 pending」を取得しない
（`hasPendingDelete` ガード＝enqueue と in-flight pull の逆転レースを閉じる）。**この判定を scan へ
展開してはならない**（復旧中の未 DL ファイルへ delete を打つ＝FSEvents `.deleted` イベント限定が
load-bearing）。残余 = 初回 read() 完了前の数秒窓・採用途中の再起動後（`remoteKnownPaths` は
非永続）・採用未了ウィンドウ中の dir 単位削除は従来どおり黙殺 → 一度復活 → 再削除で収束
（versioning 90 日で可逆）。回帰は `ThreeWayMergeTests` / `ReconcileWiringTests` /
`ScanEventWiringTests`。

## アップロード競合の folderSync 側解決（`SyncEngine.resolveUploadConflict`）

判定・検出は共有（`docs/04`「アップロード側の並行更新検出」）。folderSync 側の解決は
**回復可能順序**が要:

1. キュー行を **item.id 基準で除去**（give-up 加算なし）
2. ローカル編集を `(local copy …)` へ退避（`renameLocalForConflict`）
3. リモート版を **versionId 指定**で正規パスへ取得（`Downloader.download(versionId:
   clearQueueByPath:false)`。本体 PUT が「最新」を自分の内容に変えているため最新取得では相手版を
   取れない。`clearQueueByPath:false` で同 path の新 id 行を巻き込まない）
4. `.conflictCopyCreated` を通知。退避コピーは新規ファイルとして再アップロードされる

リネームはキュー行除去を決して上回らない（さもないと canonical 欠落 + 行残存で再処理が
delete-marker を打つ）。rename/download が失敗しても次回 pull が自己回復する。
結合テストは `UploaderConflictTests`。

## folderSync 固有のセキュリティゲート

共有ゲート（PathValidator 字句検証・`NoFollowFileReader`・streamObject の有界化）は
`docs/04`「セキュリティゲート」。folderSync 固有分:

- フルスキャンはシンボリックリンクを追従しない。走査は再帰下降（`walkSyncTree`・#64）で symlink
  （dir リンク含む）を**スタックへ push しない**＝構造的に降りない。`.syncignore` の discovery 走査
  （`loadLayeredIgnore`・pull 末尾専用）は enumerator ベースのままで、symlink item は `continue`
  のみ（**symlink item で `skipDescendants()` を呼んではならない** — 無関係な隣接ディレクトリへの
  再帰がスキップされ、実在する追跡ファイルが削除検出に乗って S3 へ誤 delete される。Issue #54）
- Downloader の書き込み先（最終コンポーネント）がシンボリックリンクなら拒否
- 書込・削除経路（Downloader の `download` / `applyRemoteDeletion` / `renameLocalForConflict`）は
  `PathValidator.resolveForWrite` を通し、**祖先ディレクトリの symlink 経由のルート脱出**も拒否する
  （F2 / M6）

詳細は `security/critical.md` C1 / C2、`security/medium.md` M3–M6、`security/low.md` L9。
