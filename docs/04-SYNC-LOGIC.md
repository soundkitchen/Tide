# 同期ロジック

> **スコープの現状（v0.3.0・2026-08-17）**:
> - 稼働モードは **fpOnly（File Provider）のみ**。同期面は FP ドメイン（`~/Library/CloudStorage/Tide`）で、
>   書き手は FP 拡張（`TideFileProvider.appex`）、リモート変化検知はアプリ側の `RemoteChangeSignaler`。
>   アプリ・拡張とも**ローカル DB には一切触れない**。本書はこの現行 fpOnly の同期ロジックを記述する。
> - 旧 folderSync（FSEvents）世代の同期ロジック（フルスキャン / イベント駆動 / アップロードキュー /
>   pull・reconcile）は **[`04a-SYNC-LOGIC-FOLDERSYNC.md`](04a-SYNC-LOGIC-FOLDERSYNC.md) へ退避**した
>   （デッドコード仕様の記録・削除予約。到達は git revert のみ = `docs/09`「revert 復帰ランブック」）。
> - 3-way merge・マニフェスト RMW・除外ルールなどの**共有純粋ロジックは本書が正**（FP 経路が現役で使う）。

## 全体像（fpOnly）

```
[ローカル → S3]（書込方向）
  Finder / アプリでの作成・編集・削除・リネーム
     │ fileproviderd（OS デーモン）
     ▼
  FP 拡張の書込コールバック（createItem / modifyItem / deleteItem）
     │ ExtensionWriter
     ▼
  S3 本体 PUT / delete marker + マニフェスト RMW（ManifestUpdater = 共有チョークポイント）

[S3 → ローカル]（取り込み方向）
  RemoteChangeSignaler（アプリ・index.json の HEAD ETag 比較・既定 180 秒）
     │ 変化時のみ signalEnumerator(.workingSet)
     ▼
  FP 拡張の enumerateChanges（マニフェスト世代 diff → dataless プレースホルダ更新）
     │ ユーザがファイルを開いた瞬間
     ▼
  fetchContents（S3 から streaming 取得 + サイズ / SHA-256 検証 = materialize）
```

「拡張 = 第 3 のデバイス」方式: 拡張は S3 とマニフェストだけを読み書きし、アプリの DB / tmp には
触れない。多端末の整合はマニフェスト RMW 内の 3-way 判定（`decideUpload`）が一元的に裁く。

## FP 取り込み経路（S3 → ローカル）

### RemoteChangeSignaler（アプリ側・変化検知）

`Tide/Core/RemoteChangeSignaler.swift`（@MainActor・@Observable）。

- `.tide/index.json` の **HEAD ETag** をポーリング間隔（`ConfigStore.pollingIntervalSeconds`・
  既定 180 秒・下限 30 秒クランプ）+ 起動時 / wake / ネットワーク復帰の即時契機で比較し、
  変化時のみ `FileProviderController.signalRemoteChanges()`（coalesce は FP 側）。
- 増分取り込みの本体は拡張の `enumerateChanges` が担うため、アプリの仕事は通知だけ
  （HEAD 1 発 ≒ 数十バイト/周期）。
- **不変条件**: ① DB / `shard_state` 非接触（構造的に依存を持たない = folderSync 凍結資産を進めない）
  ② index 不在（未セットアップ / 空バケット）は無反応・ベースラインも作らない ③ HEAD 失敗は保持
  ETag を進めない（一過性エラーで変化を取りこぼさない）④ 初回チェックはベースライン確立 +
  無条件 1 回 signal（停止中に溜まった変化の取り込み保険）。詳細は `docs/08`「FP-only 稼働モード B-0」節。

### 拡張の列挙と世代キャッシュ

列挙はマニフェスト駆動で DB 非依存: `ManifestSnapshotLoader`（index + 全シャード読み・書込ゼロ）→
`ManifestTree`（パスツリー化）→ `ManifestGenerationCache`（世代 = SyncAnchor 付き TTL キャッシュ）。
`enumerateItems` / `item(for:)` / `fetchContents` は TTL 内キャッシュを使い、signal 応答
（`enumerateChanges`）だけ TTL を待たずリフレッシュする（変更前キャッシュで「変更なし」と誤答して
signal を消費しない）。世代の系譜は `ManifestGenerationLog`（App Group Caches）が持ち、未知 anchor は
`syncAnchorExpired` でシステムに全再列挙させる。

### enumerateChanges（増分配信）

起点世代（呼び出し元 anchor）と現行世代の **`ManifestTreeDiff`** を `didUpdate` / `didDeleteItems` で
配信し、anchor を前進させる。

- item identifier は **kind 織り込み形式**（ファイル = `f:<path>` / ディレクトリ = `d:<path>`・
  M5 Phase 5-1）。種別変化（file ⇄ dir）は「旧 kind ノードの delete + 新 kind ノードの update」=
  別 id の独立した 2 変化になり、fileproviderd の同一 id ingest 合成問題を構造的に回避する（後述）。
- 実体化バッジ（Issue #65）は anchor 意味論と独立の eventual オーバーレイとして working set の
  enumerateChanges（**唯一の報告点**）に合流する。詳細は `docs/08`「FP 実体化連動バッジ」節。

### fetchContents（materialize・読み取りの本丸）

dataless プレースホルダを開いた瞬間に呼ばれる。

1. キャッシュ済みツリーから該当 entry（size / sha256 / s3VersionId）を引く
2. **マニフェストが指す versionId を第一候補**で `streamObject`（enumerate と fetch の間に最新版が
   変わっても、提示済み itemVersion と中身が食い違わない）。その版が失効している場合のみ最新版へ
   フォールバック（内容の同一性は次の SHA ゲートが保証）
3. ドメイン用 tmp へ streaming 書込しつつ SHA-256 を逐次計算
4. **commit 前検証**: 実書込サイズ == `entry.size` かつ SHA-256 == `entry.sha256`。不一致は
   `noSuchItem` では**なく** I/O エラー（item を消させず後で再試行可能に）。`noSuchItem` は
   「最新版も無い = 本当に消えている」時だけ（デーモンがプレースホルダごと item を削除するため）

## FP 書込経路（ローカル → S3）

### 書込コールバックと ExtensionWriter

`createItem` / `modifyItem` / `deleteItem`（+ rename / reparent = `modifyItem` の
filename / parent 変化）を `TideFileProvider/ExtensionWriter.swift` が処理する。

- **内容書込**（`modifyFileContents`）: 本体を PUT（16 MiB 超はマルチパート）→
  `ManifestUpdater.updateFileEntry(for:base:newEntry:)` で確定。3-way ベース `base` は
  **FP の `baseVersion`（= itemVersion に符号化した sha256）**から取る（DB 不要）。
  新規作成（createItem）は `base: nil` で `decideUpload` の三分岐（作成 / 冪等 / 競合）に合流する。
- **削除**: 単発 = `removeFileEntry(for:base:)`、ディレクトリ再帰削除 = `removeFileEntries` の
  シャード単位バッチ RMW（往復はシャード数で有界 ≤256）。順序は**マニフェスト除去 → deleteObject
  （delete marker）**で、権威判定点は RMW 内・ベース不一致は拒否側。
- **rename / reparent**: `S3Client.copyObject`（**versionId 固定・最新版フォールバック禁止**）+
  `moveFileEntries` の二相バッチ RMW（全 add → remove・中間状態は常に両存側）。
  詳細は `docs/08`「FP 双方向書込」「rename / reparent」節。
- 書込確定後は世代キャッシュを invalidate + 自己 signal（自世代 append で bounce 防止）。
- 現行の書き手は S3 オブジェクトに**ユーザーメタデータ（`x-amz-meta-*`）を付けない**。整合性の
  真実は `ManifestFileEntry.sha256`（folderSync 世代の metadata 規約は `docs/04a` / `docs/02`）。

### 大きいファイル（マルチパート + 1 ファイル上限）

サイズで経路を分岐する（`PartPlan` は FP / folderSync 共有の純粋ロジック）。

- **シングルパート**（`≤ 16 MiB`、`PartPlan.shouldUseMultipart` が false）: 単一 FD から読んだ
  バッファでハッシュも本体も賄い、`putObject` で送る。
- **マルチパート**（`> 16 MiB`）: `MultipartUploader` が単一 FD から順次読込しつつ SHA-256 を
  逐次更新し、読み終えたパートを**有界並列（最大 3）で UploadPart**。アダプティブパートサイズ
  （`PartPlan`）: 目標パート数 9,000 基準値を `[5MiB, 64MiB]` にクランプ、10,000 パートに
  収まらない超巨大ファイルのみ必要分まで partSize を上げる。瞬断はパート単位リトライで吸収し、
  恒久失敗は best-effort `abort` → throw（リトライは fileproviderd の再試行が担う）。
  folderSync 世代の checkpoint 永続化・stale UploadId 回収は `docs/04a` / `docs/08`。

**1 ファイルあたりのアップロード上限**は `ConfigStore.uploadSizeLimitBytes`（Settings で変更、
既定 1GiB、`-1` = 無制限・判定は `PartPlan.isWithinUploadLimit`）。上限はアップロード方向のみに
適用し、ダウンロード（materialize）は常に許可する。例外: **S3 内復元**（`S3RestoreService`・
M5 Track B-2）は再アップロードを本質的に伴うため、上限を **DL 前**に適用して
`SyncError.fileTooLarge` で拒否する（`docs/08` B-2 節）。

## マニフェスト更新の実装

書込は全経路が **`ManifestUpdater`**（`TideCore/S3/Uploader.swift`）の共有チョークポイントを通る:
`updateFileEntry(for:base:newEntry:)` / `removeFileEntry(for:base:)` /
`removeFileEntries(expecting:)` / `moveFileEntries(_:)`。呼び出し元は FP 拡張（`ExtensionWriter`）と
アプリの `S3RestoreService`・`.syncignore` seed（folderSync 世代では `Uploader` 本体）。

楽観的ロック（CAS）の骨格:

1. 権威シャードを `getShard`（`ManifestFetch` = 値 + ETag）で取得
2. RMW 内で 3-way 判定（`decideUpload` / 削除ベースガード）→ 変換適用
3. `putShard(_:ifMatch:)` で条件付き PUT（新規シャードは `If-None-Match: *`）
4. index.json を `IndexUpdateCoalescer`（プロセス内 actor）経由で更新 — 呼び出し側は自分の
   transform を含む putIndex の確定を await してから戻る（**shard + index 双方確定時のみ成功**。
   この確定点を崩す遅延集約は禁止 = `docs/08`「バースト RMW 競合の恒久対処」）

- リトライは **`ConditionalRetryPolicy`**（Issue #91 でポリシー化）: shard 用 = 5 回・100ms 起点
  ×2 逓増・上限 1.6s / index 用 = 8 回・上限 2s。バックオフには ±25% ジッタ。
  **再試行対象は 412 PreconditionFailed / 409 ConditionalRequestConflict のみ・`SyncError` は素通し**
  （`uploadConflict` をリトライに飲ませない）。412/409 再フェッチ時は同 retry 内で 3-way を再評価
  = 無音上書きの窓は実質ゼロ。
- **部分完了 marker（#91）**: シャード書込**確定後**の index 失敗は
  `SyncError.indexUpdateFailedAfterCommit` / 削除系 outcome `.removedIndexStale` で区別され、
  FP 拡張はこの場合**のみ** delete marker を発行してよい（シャード未確定の失敗で marker を打つと
  live オブジェクトへの marker = 不整合）。marker 発行後もエラー返却は維持する
  （fileproviderd 再試行 = stale index の治癒ドライバを殺さない）。

### シャード削除のケース

ファイル削除でシャードが空になった場合は、S3 のシャードオブジェクトを `deleteShard` で消し、
index からもエントリを除去する（空シャードは作らない）。空にならない通常更新は
`putShard(_:ifMatch:)` + index 更新。

## 競合解決（3-way merge）

M3 サブ C で **ベース / ローカル / リモートの 3 SHA による 3-way merge として形式化**した
（2026-06-04）。判定は純粋関数 `ThreeWayMerge`（`TideCore/Core/ThreeWayMerge.swift`）に集約する。

> **現行の到達点**: fpOnly で生きた呼び出し元は **`decideUpload`（`ManifestUpdater.updateFileEntry`
> 内）のみ**。pull 側判定 `decide(base:local:remote:)` の呼び出し元
> （`SyncEngine.reconcileRemoteEntry` / `Downloader.applyRemoteDeletion`）は folderSync 世代の
> デッドコードで、**到達は git revert による folderSync 復帰時のみ**（配線の記録は `docs/04a`）。
> 判定表は共有純粋ロジック（回帰 = `ThreeWayMergeTests`）としてここに残す。

ローカル状態は `LocalState`（`.absent` / `.unreadable` / `.present(sha)`）で表す。
下表の「あり」は SHA が取れた `.present`。ベースは「最後に同期した時点の SHA」
（folderSync = `FileRecord.sha256` / FP = `baseVersion` の sha）。

| ローカル状態 | リモート状態 | 動作 | `MergeDecision` |
|---|---|---|---|
| 無 / DB 記録なし（未追跡）or SHA != remote | あり | ダウンロード（クリーンインストール復旧・再セットアップ / 削除後にリモートが変化＝リモート勝ち） | `.download` |
| 無 / SHA = base（前回 sync 時）= remote | あり | **取得しない**（ローカル削除の伝播待ち。Issue #68） | `.awaitLocalDeletePropagation` |
| あり / SHA = remote | あり | スキップ + メタデータのみ最新化 | `.localMatchesRemote` |
| あり / SHA != remote / SHA = base | あり | ダウンロード（remote が新しいと判断） | `.download` |
| あり / SHA != remote / SHA != base（or 記録なし） | あり | **コンフリクト**: `<stem> (local copy YYYY-MM-DD HH-MM-SS).<ext>` へ退避 → remote を取得 | `.conflictThenDownload` |
| あり / SHA = base | 無 | ローカル削除（リモート削除の反映） | `.deleteLocal` |
| あり / SHA != base（or 記録なし） | 無 | **温存**（ユーザがローカルで編集中とみなす） | `.keepLocalRemoteDeleted` |
| 無 | 無 | 何もしない | `.noop` |

**`.unreadable`（在るが SHA を計算できない）の扱い**: 乖離の有無を確認できないので**データ安全側**へ
倒す — リモートあり → `.conflictThenDownload`（退避してから取得）/ リモート無 →
`.keepLocalRemoteDeleted`（温存）。リネーム規則は `ConflictNamer.localCopyRelativePath(for:at:)`
（時系列ソート可能書式・dotfile / 拡張子なし対応）。`.awaitLocalDeletePropagation`（#68）と
再セットアップ採用未了ウィンドウ（#69）の folderSync 側配線は `docs/04a` を参照
（fpOnly ではローカル削除が `deleteItem` コールバックで同期的に伝播するため、この pull レース自体が
存在しない）。

### アップロード側の並行更新検出（last-writer-wins 解消・Issue #25 / A・2026-06-23）

競合検出はアップロード側にも対称適用されており、**FP 拡張の書込もこの経路を通る**（現行の主経路）。
並行更新は常に「2 番目の書き手」で検出される（1 番目は書込時 remote == base なので無競合）。

- **判定**: 純粋関数 `ThreeWayMerge.decideUpload(base:uploading:remote:) ->
  UploadMergeDecision{proceed, alreadyUpToDate, conflict}`。`base` = 最後に同期した sha
  （FP = `baseVersion` / folderSync = `FileRecord.sha256`）、`uploading` = 今アップロードした sha、
  `remote` = 権威シャードの現 entry sha。`remote==nil`→`proceed`（作成）、
  `remote==uploading`→`alreadyUpToDate`（別書き手が同一内容を確定済み・書込不要）、
  `remote==base`→`proceed`（通常）、それ以外→`conflict`。
- **検出**: `ManifestUpdater.updateFileEntry` が RMW 内のフェッチ済みシャードから権威 entry を読み
  （追加 GET なし）判定。`.conflict` は `SyncError.uploadConflict(path:remoteEntry:)` を投げて RMW を
  安全中断（412/409 クラシファイアにマッチさせず即伝播）。
- **解決（FP 側・現行）**: `ExtensionWriter.modifyFileContents` が `uploadConflict` を捕捉し、
  ローカル編集内容を **conflict copy の別 path**（`ConflictNamer.localCopyRelativePath`）として
  上げ直す（`base: nil` で entry 確定）。**正規パスはリモート版が勝つ**（pull 側
  `.conflictThenDownload` と対称の意味論）。folderSync 側の解決
  （`SyncEngine.resolveUploadConflict` = キュー行除去 → リネーム退避 → versionId 指定 DL）は
  `docs/04a`。
- **残存レース / orphan version（いずれも data loss でない・versioning backstop）**: 本体 PUT は
  判定の前に走るため、`.conflict` / `.alreadyUpToDate` のどちらでも自分の PUT 版がマニフェスト
  未参照の orphan S3 version として残る。**すべての読みは manifest の versionId 経由**なので
  orphan は決して配信されず、ライフサイクルの noncurrent 失効で回収される（事前 GET + TOCTOU 窓を
  避けるための設計トレードオフ）。2 台同時 `.conflict` は互いのコピーができ得る（稀・自己収束）。

全分岐は `ThreeWayMergeTests`（`decideUpload` テーブル）で固定する。

## 除外ルール

### ハードコード除外（機密網）

`HardcodedIgnoreRules`（`TideCore/Core/IgnoreRules.swift`）。プロパティは `exactNames`
（OS ジャンク + `.tide` + `.aws`/`.ssh`/`id_rsa` 等の機密 dotfile）、`prefixPatterns`、
`suffixPatterns`（`.pem`/`.key`/`.p12`/`.pfx`/`.keystore`）、判定メソッドは
`shouldIgnore(relativePath:)`。**常に最優先**で効き、`.syncignore` の否定 `!` でも覆せない。
新しい dotfile / 拡張子で機密が紛れ込みそうなら即追加する運用（CLAUDE.md 参照）。

### `.syncignore`（ユーザ除外・M3）

gitignore 構文の一般的サブセット。詳細な確定仕様は `docs/07-M3-IMPLEMENTATION-GUIDE.md`
サブタスク B と `docs/08` を参照。要点:

- ユーザパターンは**新規ファイルにのみ**適用する（gitignore 純正）。既に同期済みのファイルは
  触らない。バックアップから外したい時はローカル削除 → 通常の削除伝播で消す。
- `.syncignore` 自身は同期対象に含める（S3 経由で全デバイスに伝わる）。ネスト `.syncignore` は
  git 風の階層適用（浅い→深い順に合成・深い層が上書き）。
- **seed（#97 で S3 直書き化）**: 新規バケットのセットアップ時のみ、`SyncIgnoreMatcher.defaultTemplate`
  を **S3 の `files/.syncignore` へ直接 PUT** し `ManifestUpdater.updateFileEntry(base: nil)` で
  entry を確定する（`AppEnvironment.seedDefaultSyncIgnoreIfNewBucket`・best-effort 非致命）。
  「新規バケット」判定は `getIndex() == nil` に加え、**損傷バケット検出の 2 段プローブ**
  （`.tide/shards/` と `files/` の `listObjectVersions` に何か見えたら seed しない — 生存カスタム
  `.syncignore` の置換や孤児化 index の新造を防ぐ）付き。呼び出しは FP ドメイン `enable()` より
  **前**（拡張の先行書込による新規バケット誤判定の防止）。
- **現行の適用点（fpOnly）**: FP 拡張の **`createItem`** が唯一の新規流入口で、
  `IgnoreDecision.shouldSkip(relativePath:isAlreadyTracked:matcher:)`（folderSync 3 経路と同一関数・
  同一優先順位）で判定し、該当は `NSFileProviderError(.excludedFromSync)` = ローカル温存・S3 非汚染。
  matcher の構築はローカルフォルダが無いため**マニフェスト経由**: `ManifestIgnoreCache` が同期済み
  `.syncignore` 群を **versionId 固定 + sha 検証**で取得し `LayeredSyncIgnore` を組む
  （`security/low.md` L17）。folderSync 世代の 3 適用点（scan / event / reconcile）は `docs/04a`。

## エッジケース

### 種別変化（file ⇄ dir）

FP 経路では item identifier の kind 織り込み（`f:`/`d:`・M5 Phase 5-1）により「旧 kind の delete +
新 kind の update」= 別 id の独立変化として配信され、fileproviderd の同一 id ingest 合成問題は
構造的に存在しない。folderSync 世代の同名置換バグと三層防御（**ファイルが同名ディレクトリへ
置換された** / Issue #52）の記録は `docs/04a` を参照（コア修正は温存コードに残存・回帰は
`ScanEventWiringTests` 等）。

### ファイル名がプラットフォーム依存

macOS は NFD（分解形式）でファイル名を返す。S3 にはこれをそのまま渡す。NFC（合成形式）への正規化は
**しない**。ローカルの実態と一致させる方が安全。

## セキュリティゲート（fpOnly）

- リモート（マニフェスト / fileproviderd）由来の `relativePath` / `shardId` は **すべて**
  `PathValidator` を通す。FP 拡張には syncRoot が無いため**字句検証**
  （`validateRelativePath` = `..` / 絶対パス / NUL / バックスラッシュ / 空コンポーネント拒否）を
  S3 キー組み立て前に全件適用する（パス合成は `FileProviderWritePolicy.childPath` 経由）。
- マニフェスト系の `getObject` は `maxBytes` 16 MiB（OOM 自己防衛）。本体 DL は `streamObject` で
  チャンク・ストリーミング（メモリ有界）+ 受信累積長を `entry.size` と突合（超過破棄 = DoS ガード）。
- アップロードは **`NoFollowFileReader`（`open(O_RDONLY | O_NOFOLLOW)`）の単一 FD** で行い、
  最終コンポーネントが symlink なら拒否。ハッシュ計算と本体読込 / パート送信が同一 FD なので
  2 回 open の TOCTOU 窓は無い（M5 / F3 / L9）。
- FP `createItem` の除外強制（機密網 / symlink / `.syncignore`）は上記「除外ルール」のとおり。
- folderSync 世代のゲート（スキャン走査の symlink 非追従 / `resolveForWrite` の祖先 symlink 拒否 /
  Downloader の書込先検証）は `docs/04a` と `security/` 各票を参照。

詳細は `security/critical.md` C1 / C2、`security/medium.md` M3–M6、`security/low.md` L9 / L17。
