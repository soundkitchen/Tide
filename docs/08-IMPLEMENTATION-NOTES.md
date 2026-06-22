# Tide — 実装ノート（会話で確定した実装決定）

このファイルは旧 `CLAUDE.md` 第 7 節を分離したもの。`docs/` の仕様書本文を超えて、
会話のキャッチボールで確定した運用上の決定を集約する。新規実装で挙動を変える時は、
対応する `docs/*.md` も同時更新（→ `CLAUDE.md` 大原則 (2)）。

> `CLAUDE.md` には毎回守るべき load-bearing な不変条件の要約だけを残し（CLAUDE.md §7「実装上の不変条件」）、
> 詳細・経緯・テスト名・PR レビュー番号は本ファイルに置く。一部のトピック（3-way merge / リモート pull 単一ゲート /
> mtime 不変条件 / torn upload / reconcile stat ゲート等）は `docs/04-SYNC-LOGIC.md` に権威的記述があり、
> 本ファイルは補足。将来 topical な docs へ漸進的に寄せる。

---

### S3 / バケット運用
- **リージョン入力は `Picker`（`KnownRegions.all`）**。フリーテキストはタイポ事故が起きるので使わない。
- **バケット未存在時は「アラート → CreateBucket」フロー** (`SetupWizardWindow.runCreateBucketAndProvision`)。IAM ポリシーに一時的に `s3:CreateBucket` が要る（`docs/06-SETUP-AND-BUILD.md` 参照）。
- **HeadBucket の空ボディ 403/301 は `missingRequiredData` として届く**（HEAD は本文が無く、smithy-swift の `RestXMLError` が 404 以外で `<Code>` を読めず投げる）。この decode エラーには HTTP ステータスが乗らないため、`S3ErrorClassifier.isInconclusiveHeadError` で「不確定」と判定し、**`isNotFound` と同様に「バケットがありません。作成しますか？」の confirm を出してから `CreateBucket` を実行**する。`CreateBucket` の結果で確定: **`BucketAlreadyOwnedByYou`（既存・自分の所有）はエラーにせず使用**（複数マシン同期の既存合流）／**`BucketAlreadyExists`（他アカウント使用中）→「別の名前を」**／**`AccessDenied`（`s3:CreateBucket` 無し）→「権限が不足」**。これを誤って「既存＝エラー」にすると複数マシン同期が壊れるので注意。confirm 文言は「新規作成」前提で、既存・自己所有バケットは権限があれば HeadBucket 200 で confirm 無しに使われる。
- **ライフサイクルルールはマージ方式** (`TideS3Client.ensureLifecycleRules`)。`tide-` プレフィックスの ID で Tide 製ルールを識別し、ユーザ独自ルールは温存する。3 ID すべて揃っていれば PUT もスキップ。
- **`PutObject` は常に `serverSideEncryption: .aes256` を明示**。
- **プロビジョニング時に `enforcePublicAccessBlock()`** で 4 設定すべて true を投入。

### マルチパートアップロード / サイズ上限（M3、2026-06-02）
- **自前ラッパ方式**。`aws-sdk-swift-s3-transfer-manager` パッケージは採用しない（新規依存なし）。`TideS3Client` に `createMultipartUpload`/`uploadPart`/`completeMultipartUpload`/`abortMultipartUpload` の薄いラッパと `streamObject`（Range 対応のチャンク・ストリーミング DL。サブ D-D3 で旧 `downloadToFile` を置換）を持つ。
- **`Uploader.processUpload` はサイズで分岐**: `PartPlan.shouldUseMultipart`（閾値 16MiB）。以下は単発 `putObject`、超は `MultipartUploader`。`maxSizeM1`（旧 100MiB ハード上限）は撤廃。
- **アダプティブパートサイズ** `PartPlan.plan`: 目標パート数 9,000 基準値を `[5MiB, maxPartSize(64MiB)]` にクランプ（常駐メモリ ≈ partSize×(inflight+1) を抑える＝L11）。10,000 パートに収まらない超巨大ファイル（〜640GiB 超）だけ必要分まで partSize を引き上げる（MiB 境界切り上げで `partCount ≤ 10,000` は常に成立）。
- **`MultipartUploader` は順次読込＆ハッシュ + 有界並列(3) UploadPart**。読む順序＝ハッシュ更新順序を保つ（並列でも全体 SHA は正しい）。パート単位リトライ 3 回（指数バックオフ）でセッション内瞬断を吸収（中断・再開 (a)）。**再起動またぎの再開はサブ D-D2 で実装済み**（`ResumeContext` 経由で `transfer_state` に UploadId と完了パートを checkpoint。`resume` 指定時は失敗しても abort/clear せず MPU と進捗を保持して次回再開に委ね、`resume` なしの従来呼びは失敗時に best-effort `abortMultipartUpload`）。Range DL 再開はサブ D-D3 で実装済み（下記ダウンロード節）。
- **object metadata に `sha256` を付けない**（両経路）。create 時点で sha256 未確定 ＆ 参照経路が無いため。整合性の真実は `ManifestFileEntry.sha256`。metadata は `mtime`/`device`/`size` のみ。
- **マニフェスト `etag` は S3 返値をそのまま格納**（単発=MD5、マルチ=`<md5>-<partcount>`）。整合性は sha256 ベースなので etag パーサ不要。
- **アップロード上限は「1 ファイルあたり」**（バケット総量ではない）。`ConfigStore.uploadSizeLimitBytes`（既定 1GiB、`-1`=無制限）。**Uploader は周回ごとに `config` から読み直す**（Settings 変更が次の処理で反映）。上限はアップロード方向のみ＝ダウンロード（復元）は常に許可。
- **上限超過は黙ってスキップしない**: `SyncError.fileTooLarge` を投げ、`SyncEngine.handleProcessingFailure` がリトライせずに `recentIssues` へ明示 + `sync_log` error + キュー除去（「このファイルはバックアップされていない」を可視化）。バックアップツールでサイレントな取りこぼしは最悪なので必ず見せる。
- **大ファイルのダウンロードも `streamObject` でチャンク・ストリーミング書込**（旧 200MiB インメモリ cap を撤廃。メモリはチャンク有界）。マニフェスト経路の 16MiB cap は厳守。**復元の DoS ガード（M7）は `Downloader` 側に移動**: streaming の sink で受信累積長を `entry.size` と突合し、超過は `DownloadAbort.tooLarge` → 部分 tmp を破棄して仕切り直す（巨大本文によるローカルディスク枯渇を復元経路でも防ぐ。M4 を復元でも維持）。サイズ基準は**真実値であるマニフェスト `entry.size`**（アップロード上限は適用しない）。親ディレクトリ作成は SHA 検証後に行い、不一致時の空ディレクトリ litter を残さない。
- **Settings の上限 UI**: `SettingsWindow` の Sync セクションに **スライダ**「Upload size limit」（1〜100GB・1GB 刻み）と **Toggle「No upload size limit」**（無制限=-1）。`ConfigStore` は @Observable でないので `@State`（`noLimit` / `limitGB`）で持ち `onAppear` で読込・`onChange` で書込（write-through）。**既定 1GB より大きい or 無制限を選ぶと課金注意 caption を表示**（ストレージ容量だけでなく**通信量（転送・egress）**の課金も増える旨を明記）。新規 xcstrings キーは `extractionState:"manual"`。

### 帯域制御（サブ E・2026-06-10）
- **方式はトークンバケット**（`Tide/Core/RateLimiter.swift`）。aws-sdk-swift の高レベル `S3Client` には公開の帯域制御ノブが無い（`S3ClientConfiguration` にレート設定なし＝URLSession/CRT に委譲して全速送信）ため、アプリの送受信フィード層で律速する。レート計算は純粋関数 **`TokenBucket`**（`StabilityCheck`/`PartPlan` と同じく `RateLimiterTests` で全分岐網羅）、**`RateLimiter` actor** が単調時計（`DispatchTime`）と `Task.sleep` を担当。
- **予約（負残高許容）方式**: `acquire(n)` は `n` を即座に残高から差し引き、「残高が 0 以上へ回復するまでの待ち秒」だけ待つ。先に差し引くので並行 acquire でも公平（到着順で後続は先行分の負債も含めて待つ）に総スループットが収束する。`rate <= 0` は無制限（即返る）。`n > burst` でもデッドロックせず比例待ち。バーストはアイドル蓄積 1 秒ぶんで cap。
- **スロットル点**: マルチパート＝各 `uploadPart` スケジュール前に `acquire(part.count)`／ダウンロード＝`streamObject` の async 読みループで `sink` 前に `acquire(chunk.count)`（読込を遅らせると TCP フロー制御でサーバ送出も絞られる）／単発 PUT（≤16MiB）＝送出前に `acquire(size)`（粒度は粗いが平均は収束）。**マニフェスト・シャード・index 等の小さなメタデータ PUT/GET は律速しない**（`files/*` 本体のみ）。
- **共有リミッタ**: 同時並行転送（複数ファイル並行 UL/DL＋パート並列）が **`SyncEngine` 保持の 1 インスタンス**（upload 用／download 用）を共有して初めて合計が上限に収まる。`Uploader.uploadLimiter` / `Downloader.downloadLimiter` / `streamObject(limiter:)` に注入。**レートは config から周回ごとに `SyncEngine.refreshBandwidthLimits()` で更新**（`uploadSizeLimitBytes` と同じ「都度読み直し」流儀＝Settings 変更が次の転送周回で効く）。
- **Settings UI**: `SettingsWindow` の **「Bandwidth」セクション**に「No upload/download bandwidth limit」トグル＋ MB/s スライダ（1〜100・1 刻み・トグル off で表示）。`ConfigStore.uploadBandwidthBytesPerSec` / `downloadBandwidthBytesPerSec`（bytes/sec、**`<= 0`=無制限・既定 `-1`**）。MB/s は decimal（1 MB/s = 1,000,000 bytes/s）。`@State` + `onAppear`/`onChange` write-through。新規 xcstrings キーは `extractionState:"manual"`。**既定は無制限**（オプトイン）。

### リセット / クリーンアップ
- **`AppEnvironment.factoryReset` は `make reset` と同じ振る舞いに揃える**: Application Support / Caches / UserDefaults / Keychain を全部消す。deviceId も含めて消す（`ConfigStore.resetIncludingDeviceId`）。

### ダウンロード一時ディレクトリ
- **`TideTmpDirectory.resolve(for:)` で同一ボリュームの tmp を返す**。第一選択は `~/Library/Caches/Tide/tmp/`。同期ルートと別ボリュームになる時のみ `<syncRoot>/.tide/tmp/` にフォールバック。`moveItem` の atomic 性を保つため。

### 競合ファイル命名
- **`ConflictNamer.localCopyRelativePath(for:at:)` の命名規則**: `<stem> (local copy YYYY-MM-DD HH-MM-SS).<ext>`。
  - 例: `note.txt` → `note (local copy 2026-05-24 12-34-56).txt`
  - 拡張子なしファイル / dotfile (`.gitignore` 等) も対応済み。
  - **書式は `Date.VerbatimFormatStyle` で固定（2026-06-16 修正）**: 旧実装は `Date.FormatStyle`（`.dateTime.year().month()…`）で組んでおり、`.month()` 略称・`.hour()` 12 時間 + AM/PM のロケール表記（`Jun 16 2026 at 2-06-18 AM`）になって**辞書順が時系列にならない**バグだった（M4 通知の実機受け入れ中に発見・`sanitizeTimestamp` が想定する `"…, …:…:…"` 入力は実際には生成されていなかった）。numeric・0 埋め・24 時間の `YYYY-MM-DD HH-MM-SS` へ修正し、`Date.VerbatimFormatStyle` は Sendable なので strict concurrency でも `static let` のまま安全。`ConflictNamerTests.testTimestampIsNumericSortableFormat` がタイムゾーン非依存に書式を pin（旧来のテストは prefix/suffix とコロン無ししか見ておらず退行を検出できなかった）。`restoredCopyRelativePath`（バージョン復元の退避コピー）も同じ共通ロジックで一括修正。

### 競合解決（3-way merge・M3 サブ C）
- **競合解決の判定は純粋関数 `ThreeWayMerge.decide(base:local:remote:) -> MergeDecision` に一本化**（`Tide/Core/ThreeWayMerge.swift`）。`reconcileRemoteEntry`（pull 側）と `applyRemoteDeletion`（削除側）の両方がこれを通す。**ベース = `FileRecord.sha256`（ローカル DB）**、マニフェスト schema は拡張しない。判定ロジックを副作用から切り離し、全分岐を `ThreeWayMergeTests` で網羅（`IgnoreDecision`/`PartPlan` と同じパターン）。挙動は旧 M2 表（`docs/04-SYNC-LOGIC.md`）と 1:1 一致。
- **アップロード側の並行更新検出（last-writer-wins 解消・Issue #25 / A・2026-06-23）**。下記の専用節を参照。

### アップロード側の並行更新検出（Issue #25 / A・2026-06-23）
- **判定**: 純粋関数 `ThreeWayMerge.decideUpload(base:uploading:remote:) -> UploadMergeDecision{proceed, alreadyUpToDate, conflict}`。pull 側 `decide` と対称。全分岐を `ThreeWayMergeTests` の `decideUpload` テーブルで固定。
- **検出は書込シームで（追加 GET なし）**: `Uploader.ManifestUpdater.updateFileEntry` が `withConditionalRetry` 内のフェッチ済みシャードから現リモート entry を読み判定。`.conflict`→`SyncError.uploadConflict(path:remoteEntry:)` を投げて RMW を安全中断（`S3ErrorClassifier.isPreconditionFailed/isConditionalConflict` にマッチせず即伝播）。412/409 再フェッチ時は同 retry 内で再評価＝無音上書きの窓は実質ゼロ。`.alreadyUpToDate` は put せず、`processUpload` は DB をリモート版 identity（etag/versionId）+ ローカル stat mtime で記録して次回 pull を no-op に（`ChangeDetector.reconcileIsNoop` 成立）。
- **解決は pull 側 `.conflictThenDownload` と対称・回復可能順序**: `SyncEngine.resolveUploadConflict`（`nonisolated static`・`pruneOrphanTransfers` と同型の依存注入）。① キュー行を **item.id 基準で除去**（give-up 加算なし）→ ② `renameLocalForConflict` でローカル編集を `(local copy …)` へ退避 → ③ リモート版を **versionId 指定** + `clearQueueByPath:false` で正規パスへ取得 → ④ `.conflictCopyCreated` を @MainActor 側で通知。`@MainActor handleUploadConflict` が Downloader 構築・通知・recordIssue だけを担い、本体は `UploaderConflictTests` で結合固定。
- **なぜ versionId 取得が必須か**: 本体 PUT がマニフェスト判定より先に走るので、`.conflict` 時には `files/<path>` の**最新が自分の内容**になっている。最新取得（versionId なし）だと自分の内容を取り直して `entry.sha256` 検証に失敗する。`Downloader.download(versionId:)` で相手版を確実に取る（`RangedDownloadClient` に versionId を追加・`TideS3Client` は復元用の既存版で適合）。並行 pull（最新）との tmp 衝突を避けるため `resumeTmpURL` は versionId 指定時のみ名前に織り込む。
- **なぜ「リネーム≦キュー行除去」か**: `renameLocalForConflict` は不可逆な FS 移動 + FileRecord 削除。これがキュー行除去より先に走り後続が失敗すると、canonical 欠落 + キュー行残存で再処理が `convertQueueItemToDelete` → リモート delete-marker（他端末データ損失）。だから行を先に除去し、成功時のみリネームする。rename/download が失敗しても次回 pull が `.conflictThenDownload` / `local-absent→download` で自己回復。
- **残存レース（data loss でない・versioning backstop）**: (1) `.conflict` 時にマニフェスト未参照の orphan S3 version が 1 つ残る（読みは全て manifest の versionId 経由なので配信されない）。(2) 2 台同時 `.conflict` で互いのコピーができ得る（稀・自己収束）。

### リモート削除の取り扱い
- **「リモートで消えたファイルをローカル削除するのは、ローカルファイルの SHA が DB 記録（最後にアップロードした内容）と一致するときのみ」**（= `ThreeWayMerge` の `.deleteLocal`）。一致しなければユーザが触っているとみなし（`.keepLocalRemoteDeleted`）、`sync_log` に warning を残してスキップ。`Downloader.applyRemoteDeletion`。

### `.syncignore` 除外ルール（M3）
- **構文は gitignore の一般的サブセット**: `*` `**` `?`、先頭 `/` アンカー、末尾 `/` でディレクトリ限定、`!` 否定（再包含）、`#` コメント、空行。`SyncIgnoreMatcher` がグロブを**トークン列**に変換し、照合は **reachable-set DP**（`O(パターン長 × パス長)`）で行う（**ユーザ正規表現は受けない**）。サイズ上限 256 KB / パターン数上限 10,000。
- **ReDoS は構造的に解消済み（F1 / L8、2026-06-04）**: 旧来は生成正規表現を `NSRegularExpression`（ICU = バックトラッキング）で照合していたため `*a*a*…` 系で破滅的バックトラッキングが起こり得たが、`NSRegularExpression` を廃して線形時間照合（トークン列 + reachable-set DP、バックトラッキング無し）に置換した。`parse` の上限（`maxPatternLength` / `maxWildcardsPerPattern` / `maxMatchPathLength`）は ReDoS 防御の load-bearing ではなくなったが、**防御的サニティ上限として保持**（資源消費の有界化）。意味論は旧 regex 実装との differential fuzz（`SyncIgnoreMatcherTests.testLinearMatcherMatchesReferenceRegex`）で同値を担保。
- **ハードコード除外（機密網）は常に最優先**。`.syncignore` の否定 `!` では `.env` 等を再包含できない。「既存は触らない」緩和は**ユーザパターンにのみ**適用し、ハードコード除外には適用しない。
- **gitignore 純正（既存は触らない）**: `.syncignore` のユーザパターンは**新規ファイル（未追跡 = `FileRecord.lastSyncedAt == nil`）にのみ**適用。既に同期済みのファイルは同期継続、S3 からも自動削除しない。バックアップから外したい時はローカル削除 → 通常の削除伝播。
- **`.syncignore` 自身は同期対象に含める**（S3 経由で全デバイス・復旧後にも伝播）。`IgnoreDecision.shouldSkip` は `.syncignore` 自身を決して除外しない。
- スキップ判定は純粋関数 **`IgnoreDecision.shouldSkip(relativePath:isAlreadyTracked:matcher:)`** に集約し、`performFullScan` / `processEventToQueue` / `reconcileRemoteEntry` の 3 経路すべてで通す。`.syncignore` の読込は `PathValidator.resolveSafely` 経由 + symlink 非追従。`.syncignore` 変更は FSEvents で拾って `reloadIgnoreMatcher()` + フルスキャン再評価。
- **既定テンプレートの自動生成**: `AppEnvironment.completeSetup` で、**ローカルに `.syncignore` が無く、かつリモートにマニフェスト（`getIndex()`）も無い「新規バケット」のときだけ** `SyncIgnoreMatcher.defaultTemplate`（`node_modules/` 等の再生成可能な開発ジャンク）を `<syncRoot>/.syncignore` に書き出す。**既存バケットに参加する場合は作らない**（他デバイスの `.syncignore` と競合してコンフリクトコピーが散らかるのを防ぐ）。`HardcodedIgnoreRules` とは別物（ユーザが編集・削除でき、`!` で上書きも可能）。`.git/` は復旧目的のためテンプレートに含めない＝同期対象のまま。

### `xcodegen` / Xcode プロジェクト
- **`Tide.xcodeproj/` は git 追跡対象**。`make generate` 後の差分も同じコミットに含めるのがルール。
- xcuserdata は除外。

### `Localizable.xcstrings` の運用
- **新規キーには必ず `extractionState: "manual"`** を付ける（Xcode の自動 purge を防ぐため）。
- **「キーが既に登録されていないか」を編集前に `grep` で確認**（汎用語の重複事故が起きやすい — 過去に `"Region"` 重複で JSON が壊れた）。

### UI 起動・遷移
- **`MenuBarExtra(.window)` のポップオーバー内ボタンから `openWindow(id:)` を呼ぶときは、`NSApp.activate(ignoringOtherApps: true)` を必ず前置**。LSUIElement = YES のアプリだとアプリがフォアグラウンドに来ておらず、新しいウィンドウが obscured になる。

### 転送進捗 UI（サブ D-D4）
- **進行中の大ファイル転送はメニューバーのポップオーバー（`MenuBarContent`）に「Transferring」セクションで表示**（方向アイコン + ファイル名 + % + `ProgressView`）。状態は `SyncEngine.activeTransfers: [TransferProgress]`（@Observable・MainActor）。
- **進捗の流れ**: off-main の `Uploader`/`Downloader` が `@Sendable TransferProgressReporter`（`begin`/`update`/`end`）を発行 → `SyncEngine` が `Task { @MainActor }` で `applyProgress` に集約。**reporter が生む Task の到着順は前後し得る**ので、`update` は既存エントリの**増加方向のみ**適用し、`begin` で作成・`end` で除去する（(path, direction) で一意）。MainActor へのホップを抑えるため、アップロードはパート完了ごと、ダウンロードは ~4MiB ごとに coalesce して報告する。シングルパート（≤16MiB）は進捗を出さない。`stop()` で `activeTransfers` をクリア。

### Bootstrap 失敗時の挙動
- **`AppEnvironment.bootstrapFailure` に詳細理由（どのフィールド / Keychain 読みでコケたか）を入れる**。`MenuBarContent` はその値を見て自動的にセットアップウィザードを再表示する。

### Bootstrap の起動契機（eager・2026-06-05）
- **bootstrap は `@NSApplicationDelegateAdaptor` の `AppDelegate.applicationDidFinishLaunching` から起動時に eager 実行**する（`AppEnvironment` も `AppDelegate` が `let` で保持し、Scene へ `.environment(...)` で配る）。`MenuBarExtra(.window)` のポップオーバーコンテンツは**初回オープン時に初めて生成**されるため、bootstrap を `MenuBarContent.task` だけに置くと**メニューを開くまで SyncEngine が立ち上がらない**（ログイン自動起動後・アプリ再起動後に無同期＝中断再開も走らない）。
- **`MenuBarContent.task` の bootstrap 呼びは残す**（未設定時のウィザード表示の保険）。両経路から呼ばれても二重起動しないよう、**`AppEnvironment.bootstrap()` は `engine != nil`／`isBootstrapping`（`@ObservationIgnored`）で再入ガード**する（`await launchEngineFromCurrentConfig()` 実行中にもう一方が guard を抜けるのを防ぐ）。
- **`bootstrapFailure` の自己修復を温存**（PR #7 レビュー Medium）: `engine != nil` の早期 return では **`bootstrapFailure = nil` してから return** する（さもないと「失敗→ウィザードで復旧→正常稼働」後も値が残り、ポップオーバーを開くたびにウィザードが再表示され続ける）。`isBootstrapping` 中の return では触らない。**`completeSetup` も成功直後に `bootstrapFailure = nil`**。
- **`completeSetup` の二重起動防止**（PR #7 レビュー Low）: `setupCompleted` を立てた後の `seedDefaultSyncIgnoreIfNewBucket`／`launchEngineFromCurrentConfig` の await 中に `MenuBarContent.task` の bootstrap がエンジンを二重起動しないよう、**`completeSetup` でも `isBootstrapping` を立てる**（`defer` で解除）。

### リモート pull の単一ゲート化 + ダウンロード実サイズ検証（2026-06-05・サブD受け入れテストで発見・修正）
- **すべてのリモート pull は `SyncEngine.triggerRemotePull()` の単一ゲート（`isRemotePulling`）を必ず通す**。start()（起動時）・メニューの「S3 から取得」・poll / wake / network のすべてがこの公開メソッド経由で**直列化**される（@MainActor なので check→set 間に await が無く割り込まない）。
- **手動 pull は coalescing（2026-06-07・PR #9 レビュー ④）**: pull 進行中の再入のうち**手動（`reason == .manual`）だけは pending 化し、現 pull 終了後にもう 1 周**する（reason は `.manualCoalesced`）。`reason` は coalescing の分岐条件を持ったため **`SyncEngine.PullReason` enum**（ログは rawValue。stringly-typed だと呼び元追加時のタイポで coalescing が黙って効かなくなる。PR #10 レビュー Low-2）。poll/wake/network は次の周期が来るので従来どおりドロップ。`isRemotePulling` は `@Observable` 公開状態（`private(set)`）で、「Pull from S3」ボタンは pull 中スピナー + 「Pulling…」に切り替え（**enabled のまま**＝押下が coalescing の入口。disabled にすると pending 化の入口が無くなる）。coalesced ラウンドの継続条件は `pendingManualPull && running && !Task.isCancelled` — **`stop()`（factory reset 経路含む）後や呼び元タスク cancel 後に新ラウンドを開始しない**（PR #10 レビュー Low-1。in-flight の 1 周は既存挙動どおり走り切る）。
  - **これを欠くと致命的バグ**: 起動時 pull が `triggerRemotePull()` を無防備に直呼びしていたため、初回 network-up 等の pull と**並行**し、同一ファイルを 2 つの reconcile が同時 DL → **決定的 tmp `dl-<sha(path)>.part`（ファイル別ロック無し）への並行追記でファイルが過大化・破損**。さらに各 DL は自分の論理 SHA でゲートを通過し、`updateDBEntryAfterDownload` が実サイズでなく `entry.size` を記録するため見逃され、**commit → 監視経由で再アップロード → リモートのマニフェストまで汚染**した（バックアップ/復元ツールとして最悪のサイレント破損）。
- **`Downloader.download` は commit（tmp→本体への move）前に「実 tmp サイズ == `entry.size`」を必ず検証**し、不一致なら破棄して仕切り直す（防御の二段目）。ストリームの `total` は論理量で共有 tmp への並行追記を捕捉できないため、**実ファイルサイズ**を突合する。

### mtime の不変条件と SHA ゲート（2026-06-08）
- **不変条件: 「`FileRecord.mtime` = 最後に同期した時点のローカル stat mtime」**。マニフェスト `mtime` は ISO8601 秒精度（fractional なし・`Manifest.swift` の `ISO8601.format`）なので、これで DB を上書きしてはならない（フルスキャンの `< 0.001` 比較が常に外れ、無変更ファイルが毎起動再アップロードされる。docs/09 の修正済み項目参照）。pull の内容一致時の DB 最新化（`Downloader.markSynced`）は**ローカル stat 実値**を記録する。stat は **sha 計算の前に**行う（ハッシュ中の書換でも「旧 mtime + 旧 sha」の組で残り次回再検出される安全方向。後 stat は「新 mtime + 旧 sha」で取りこぼしが恒久化する）。
- **変更判定は純粋関数 `ChangeDetector`（`preDecision`/`postHash`）に集約**し、`performFullScan` / `processEventToQueue` の両経路で共用（docs/04 の SHA ゲート仕様の実装）。size 一致 + mtime 不一致のときだけ SHA を再計算し、一致なら **CAS（`LocalDatabase.refreshMtimeIfShaUnchanged`）で mtime のみ修復**してアップロードしない（`lastSyncedAt` 保持・sha 不一致なら no-op = 並行 pull の更新を巻き戻さない）。size 不一致は hash せず直接 enqueue（sha が一致し得ないため仕様と同義）。`processEventToQueue` は @MainActor なので **hash は `Task.detached` 経由**。
- **`parseISO8601`（`Downloader.swift`）は fractional seconds をパースできず nil → now フォールバックする**。マニフェスト mtime に fractional を足す変更は禁忌（フォーマット側だけ変えるとパース全滅）。

### torn upload と in-flight collapse の解消（L6・2026-06-09）
- **キュー行のライフサイクルは `item.id` 基準で扱う（`path` 基準にしない）**。enqueue は `INSERT OR REPLACE`（`upload_queue.UNIQUE(path)`）で、処理中に届いた新イベントを**新しい AUTOINCREMENT id の行**に置換する（＝完全版を上げ直せという正当な指示）。完了/失敗処理（`Uploader.processUpload`/`processDelete`、`SyncEngine.handleProcessingFailure` の retry/give-up/size-limit、`convertQueueItemToDelete`）が `path` 基準で削除・更新すると、旧 in-flight 行の完了がこの新行まで巻き込み消去し、ローカル≠DB≠リモートの**無エラー乖離**になる。**id 基準なら新行は残り次周回で再処理されて自己修復**する。enqueue 側（`handleDebounced`）は `@MainActor`＋GRDB 単一ライタで直列なので、`DebounceQueue.fire` の並行はこの不具合と無関係（当初の誤診）。
- **torn を決して“コミット”しない安定化ゲート（A-detect）**。アップロードは単一 `O_NOFOLLOW` FD から読むが、読込中に書き換えられると torn な内容を S3 にコミットし得る。**読了後に同 FD を再 `fstat` し、開始時の (size, mtime) と size 変化 or mtime 前進があれば不安定**とみなす（純粋関数 `StabilityCheck.isStable`・`Tide/Core/StabilityCheck.swift`）。シングルパートは `putObject` の**前**に判定して不安定なら PUT しない（現行 S3 版を torn で上書きしない）、マルチパートは `MultipartUploader.upload` に `expectedStat` を渡し `completeMultipartUpload` の**前**に判定して不安定なら **abort +（resume 時）checkpoint クリア**（complete しないので現行版は無傷、新 mtime でフル再開）。いずれも `SyncError.fileChangedDuringUpload` を投げる。瞬断等の従来失敗は従来挙動（resume なしのみ best-effort abort）を維持し、**不安定だけ** resume でも abort+clear する（stale な MPU を保持しない）。**マルチパートは read ループ内で逐次 early-bail**（読了量 > 開始時 size＝成長／`reader.info()` の mtime 前進＝in-place 書換）し次パート PUT 前に throw する＝成長/変化し続ける大ファイルで「満額 PUT → 全 abort」を毎リトライ繰り返す課金・帯域の浪費を避ける（PR #14 レビュー Medium）。再検査間隔と警告閾値は純粋関数 `SyncEngine.unstableRetryDelay`/`shouldWarnUnstable`（比例設計のため初回警告は実際 ~48s 付近）。
- **安定しないファイル（ログ/DB 等）は give-up させず延期＋可視化**。`handleProcessingFailure` は `fileChangedDuringUpload` を **`attempts` に載せず**（5 回 give-up で恒久未バックアップにしない）、`LocalDatabase.deferUnstableQueueItem(id:nextRetryAt:)` で延期する（`attempts`/`enqueuedAt` 保持・`nextRetryAt` のみ前進）。再検査間隔は `min(max(3s, now − enqueuedAt), 300s)`＝**保留経過に比例**させ巨大ファイルの無駄な全読みを抑える（スキーマ変更なし）。保留が 30s を超えて安定しなければ「まだバックアップされていない」を `recentIssues`/`sync_log` に **1 回だけ**見せる（in-memory `unstableWarned` で dedup、アイドル周回の `pruneUnstableWarned` でキューから消えた path を間引き＝再エピソードで再警告可能）。＝**torn を出さず取りこぼしも黙らせない**。

### バージョン復元 / 削除済み復元 UI（M4・2026-06-10）

- **列挙基盤は純粋ロジックに集約**: `TideS3Client.listObjectVersions`（`ListObjectVersions` ラッパ。生 SDK 型を `ObjectVersionPage`/`S3ObjectVersionRaw`/`S3DeleteMarkerRaw` の Sendable 値に詰め替え・ページングカーソル）で取得し、整形は副作用ゼロの `ObjectVersionHistory`（相対パスごとのグルーピング・時系列降順・delete marker 判定・削除済み集合導出・`files/` 剥がし + `PathValidator.validateRelativePath` で不正キー除外）。`ObjectVersionHistoryTests` で全分岐網羅。`getObject`/`headObject`/`streamObject` は `versionId` を受ける（`streamObject` は versionId 付きオーバーロードで `RangedDownloadClient` プロトコル無変更）。
- **復元方式は「ローカルへ書き戻し → 再アップロード」**（`RestoreService`・`SyncEngine.restore(relativePath:versionId:)` 経由）。S3 内 CopyObject 方式は採らない（マニフェスト整合の設計コストが高い・docs/09 据え置き）。復元後はフルスキャンを促し FileWatcher → 通常 upload 経路で新しい**現行版**として上げ直す＝**DB は触らない**（スキーマ変更なし）。再アップロードで新マニフェストに sha256 が載る。
- **整合性は真実サイズで担保**: 過去版にはマニフェスト sha256 が無い（マニフェストは現行状態のみ）ため、履歴 DL では SHA 突合せず `headObject(versionId:)` の `Content-Length` を上限ガード（ローカルディスク枯渇 DoS = M7 を復元でも維持）＆実サイズ突合に使う。`streamObject(versionId:)` は共有 `downloadLimiter` を通す（サブ E と一貫）。
- **復元先はハイブリッド（純粋関数 `RestoreTarget.decide`）**: 原パスへ書き戻す。ただしローカルに既存ファイルがあり現在 SHA が `FileRecord.sha256`（最後に同期した内容）と食い違う＝未同期編集、または読めない（symlink/IO）なら、`ConflictNamer.restoredCopyRelativePath`（`(restored YYYY-MM-DD HH-MM-SS)`）の別名へ退避して上書きを避ける（データ損失より重複）。書込は `PathValidator.resolveForWrite` + 最終コンポーネント symlink 拒否 + 復元専用 tmp（`restore-<hash>.part`・`Downloader` の `dl-` と非衝突）→ atomic move。`RestoreTargetTests`/`RestoreServiceTests`（フェイク S3 + 実 DB/temp syncRoot）で原パス/退避分岐・サイズ超過 abort・サイズ不一致・symlink 非追従・versionId 透過を固定。
- **列挙コスト方針**: 特定ファイル履歴は `prefix=files/<相対パス>` で安価（「Versions」タブ）。全削除済み一覧は `files/` 全舐めで高コストなので**明示ボタンでのみ**フル列挙し、ページングしながら逐次表示・キャンセル可（「Deleted files」タブ）。**ポーリングには乗せない**。UI は単一「Version History」ウィンドウ（`Picker` でタブ切替）、MenuBar から `openWindow(id:"versions")`（`NSApp.activate` 前置）。`VersionHistoryModel` は `Tide/UI/`（@MainActor @Observable）。
- **Version History の競合・負荷対策（PR #16 レビュー反映・2026-06-10）**: 削除済みスキャンの再検索/キャンセルは**世代トークン**（`scanGeneration`）で stale 書込を抑止する — `Task.cancel()` は in-flight の `await listObjectVersions` 復帰後の state 書込までは止められないため、各書込前に世代一致を確認して旧タスクを捨てる（`isScanningDeleted = false` も世代一致時のみ）。累積全件の再グルーピングは `Task.detached` で off-main（MainActor 継承 Task 内で直に呼ぶと大規模バケットで UI がカクつく）。`loadVersions` は冒頭 `isLoading` 再入ガード（`onSubmit`/Choose… 経由はボタンの disabled を素通りする）。divert（別名退避）復元時は Deleted 一覧から**外さない**（原 key は delete marker のまま＝「現在削除済み」を維持）。`chooseFile` の syncRoot prefix 比較は両辺 `resolvingSymlinksInPath()`（NSOpenPanel は実パスを返しがちで、syncRoot 設定値が symlink を含むと正当な選択を弾くため）。
- **実機受け入れテスト消化済み（✅ 2026-06-11・PR #16 マージ後に対話形式で実施・チェックリストファイルは作成せず）**: Versions タブの過去版復元（原パス書き戻し → FileWatcher 再アップロード → 新現行版 → マニフェスト shard 合流まで、aws CLI の独立経路で SHA 突合＝ローカル/DB/S3 版/shard の四者一致）、Deleted files タブの全列挙（CLI 導出の期待集合 12 件と一致）と削除済み復元（delete marker の上に新現行版が `isLatest` 化・一覧から除去）、`restore-*.part` 残骸なし、を実機確認。**divert（別名退避）分岐のみ実機未消化**: watcher 稼働中はデバウンス数秒で編集が同期され「未同期編集あり」状態を決定的に作れないため、`RestoreTargetTests`/`RestoreServiceTests`（実 FS + フェイク S3）のユニット担保で完了扱い。

---

### 構造化エラー（SyncIssue・M4・2026-06-11）

- **UI に見せるエラーは構造化型 `SyncIssue`（`Tide/Models/SyncIssue.swift`）に一本化**（F4 / H2 UI 残の解消）。`SyncEngine.recentErrors: [String]` → **`recentIssues: [SyncIssue]`**（上限 50 維持・`clearIssues()` あり）。既定表示は `category` のローカライズサマリ（`localizedLabel` + 行動指針 `localizedGuidance`）のみで、**生エラー文字列は `rawDetail` に隔離**し context menu「Copy details」等のオンデマンド参照に限定する。
- **分類は純粋関数 `SyncIssueClassifier`（`Tide/Core/SyncIssueClassifier.swift`）**。判定順: ① `SyncError` の case 直マップ（`awsError` は underlying を剥がす）→ ② **型マッチ**（`URLError`/`CocoaError(file)`/`FileOpenError`/GRDB `DatabaseError`）→ ③ `S3ErrorClassifier`（403/404/412/409 の文字列マッチ）→ ④ ネットワーク系キーワード → ⑤ `.other`。**型マッチを文字列ヒューリスティックより先に置く**（PR #17 レビュー Low-1: ローカルエラーの説明文に "412"/"offline" 等が偶然含まれると部分一致が誤発火する。SDK エラーはこれらの型に該当しないので横取りは起きない）。誤分類しても rawDetail が details/コピーに残るので実害は「カテゴリ表示違い」に閉じる。全分岐 `SyncIssueClassifierTests`。
- **`status = .error(...)` も分類サマリ文字列のみ**（`SyncStatus` の enum 形 `error(String)` は変えない・最小変更）。
- **sync_log の流儀**: `event_type` はリテラル禁止で **`SyncLogEventType`**（`LocalDatabase.swift`）の rawValue を使う。エラー行は **message = 英語固定文（操作の文脈）/ details = 生エラー全文**に分離（give-up 行の message 埋め込み生文字列も廃止。過去行はそのまま・30 日 prune で自然消滅）。`SyncEngine.recordIssue(_:logAs:)` は `logAs`（英語固定文）を渡したときだけ sync_log("error") にも書く — nil は呼び元が自前 Tx 内で原子的に書く箇所（fileTooLarge / give-up / 不安定警告）と、リトライごとの重複記録を避ける箇所（give-up 前の各失敗）。これにより scan / pull / reconcile / 削除反映 / enqueue 失敗も sync_log に載るようになった。
- **読出 API**: `LocalDatabase.fetchLogs(eventTypes:beforeId:limit:)`（id 降順・`limit+1` fetch で `hasMore` 判定）。**カーソルは id**（AUTOINCREMENT 単調・一意。timestamp は REAL 同値衝突でページ境界に重複/欠落が出るため不採用）。`eventTypes` nil = 全種別、空集合 = 0 件。

### Sync Activity ウィンドウ（M4・2026-06-11）

- **単一「Sync Activity」ウィンドウ**（`TideApp` の `Window(id:"activity")`・`Tide/UI/SyncActivityWindow.swift` + `SyncActivityModel`）で sync_log を閲覧する。種別フィルタチップ（6 種トグル）+ 新しい順リスト + 選択行の詳細ペイン（path/message/details 全文 + 「Copy details」）+ hasMore 時「Load more」。**DB 内の path/message/details は英語生文字列なので必ず `Text(verbatim:)`**（ローカライズ解決に流さない・Version History と同じ流儀）。
- **ライブ更新はしない**（開時 `.task` ロード + 手動 Refresh）。診断面でリアルタイム性の要求が薄く、GRDB ValueObservation はフィルタ × ページングカーソルとの整合（observation 中の append 位置）が複雑化するため。将来 ValueObservation 化するならカーソルの巻き直しに注意。
- **`SyncActivityModel` は `LocalDatabase` を引数で受ける**（env 非依存）。temp DB だけで `SyncActivityModelTests` が完結する。`reload` は世代トークンで「最新が勝つ」（isLoading での再入拒否はしない＝フィルタ連打で最後の状態に収束）、`loadMore` は `!isLoading` ガード + 世代一致確認（進行中 reload があれば stale ページを捨てる）。
- **メニューバー「Details…」からのフィルタプリセット渡しは見送り**: 単一 `Window` Scene は値を渡せず、`AppEnvironment` に一時ヒントを持たせるのは状態の寿命管理が汚れる。ポップオーバー側に rawDetail コピーがあるので必要性も薄い（据え置き）。

### ポップオーバー刷新（M4・2026-06-11）

- **構成**（幅 320 → **340**）: statusHeader（状態アイコン + 見出し）/ syncInfoCard（Last sync / Last remote check / 待機件数。queue 0 なら行ごと省略）/ recentActivityCard（直近 3 件の upload/download/delete）/ transfersCard / issuesCard（カテゴリ別グルーピング + 件数バッジ + DisclosureGroup 展開 + Clear + Details…）/ primaryActions（Pause/Resume・Force scan・Pull の 3 等分アイコンボタン `.bordered`）/ secondaryActions（メニュー風フル幅 plain ボタン）。カード背景は `.background(.quinary, in: RoundedRectangle(cornerRadius: 8))`。
- **「All synced」判定は純粋関数 `MenuBarPresentation.headline(status:queueDepth:activeTransferCount:)`**（`Tide/UI/MenuBarPresentation.swift`・`MenuBarPresentationTests` で全分岐固定）。allSynced ⇔ **`.idle` かつ queue 0 かつ転送中 0** のみ。`.idle` でも queue > 0 / 転送 > 0 なら syncing 表示（キュー処理周回の谷間を「同期済み」と誤表示しない）。issuesCard のグルーピングも同ファイルの純粋関数 `groupIssues`（最新 issue を含むグループが先・グループ内新しい順）。
- **直近の同期ファイルは sync_log の直読み**（`fetchLogs(eventTypes: [upload, download, delete], limit: 3)`）。再読込トリガは **`.task(id: [lastSyncedAt, lastRemoteCheckedAt])`**（開時 + upload 周回完了 + リモート pull 完了。`lastSyncedAt` 単独だと pull 由来の download / 削除反映で発火しない。PR #17 レビュー Low-2）。SyncEngine にメモリ状態を増やさない（再起動で消える割に Uploader/Downloader → engine の報告配線コストが高い案は不採用）。
- **壊してはならない既存挙動**（リファクタ時の checklist）: 「Pull from S3」は pull 中も **enabled**（押下が coalescing の入口）+ スピナー／全 `openWindow` 前に `NSApp.activate`／root の `.task` bootstrap（ウィザード保険）／`Open Sync Folder` の nil disabled／Quit の ⌘Q／未設定・bootstrapFailure 分岐（**bootstrapFailure の生文字列表示はスコープ外で維持** — セットアップ復旧には全文が要る。docs/09 参照）。
- **実機受け入れテスト消化済み（✅ 2026-06-11・対話形式・チェックリストは運用どおり削除）**: ポップオーバー静的/動的（80MB を upload 2MB/s 制限下で「同期中… (1)」→ Transferring % → 「すべて同期済み」復帰 → 「最近の同期」反映。ローカル/DB の SHA 一致）、エラー系（1GiB 超スパースで fileTooLarge → 分類カード + guidance + 「詳細をコピー」= rawDetail 全文 + クリア + 詳細…遷移。sync_log は message 固定文 / details 生エラーの分離 + キュー除去を CLI 突合）、Sync Activity ウィンドウ（新しい順 / 行選択 + 詳細ペイン / **↑↓ キーボード選択**（nit-3）/ フィルタ / 全チップ off 文言 / 更新）、ja 表示（システム ja で全文言日本語）。**Low-2（pull 由来 download/削除での再読込）はロジック単純（`.task` id の束）+ 実機は upload 経路の再読込のみ確認**。**Load more は当時ログ < 200 件のため `SyncActivityModelTests` のユニット担保で消化扱い**、**未設定状態（`make fresh`）はセットアップ全消去を要する + fallback 分岐は無変更のためスキップ**。

### メニューバー status item アイコン（2026-06-18）

- **状態は「アイコンの様子」だけで表現する**（バッジ・色は使わない）。固定グリフ 4 種＝`MenuBarWave`（allSynced・月＋ゆるい波）/ `MenuBarPaused`（凪）/ `MenuBarError`（荒れた海）/ `MenuBarNotConfigured`（？＋波）。syncing 中は `MenuBarSync0…7` の **8 フレームを 8fps でコマ送り**して波が流れる様子を出す。
- **グリフ名 / フレーム名 / フレーム数のマッピングは純粋関数として `MenuBarPresentation` に集約**（`menuBarIconName` / `isSyncing` / `syncFrameCount` / `syncFrameName(_:)`）。`MenuBarLabel` はそれを引くだけ（FPS だけは View 側の `syncFPS`）。文字列ベースの `Image(MenuBarPresentation.syncFrameName(n))` はアセット追加漏れがコンパイル時に弾けず**無言の空画像**になりうるので、`MenuBarPresentationTests` でマッピング全分岐固定 + 全グリフ / 全フレームの `NSImage(named:)` 実在を担保する（テストホストが `Tide.app` なので本番と同じ main bundle を引く）。
- **全アセットは template-rendering（モノクロ）**（imageset の `template-rendering-intent: "template"`）。メニューバーの明暗（ダーク/ライト）にシステムが自動追従する。各 3 解像度（`*_18` / `*_36` / `*_54` = 1x/2x/3x、status item の高さ ~18pt）。
- **表示状態はポップオーバー見出しと同じ純粋関数 `MenuBarPresentation.headline(status:queueDepth:activeTransferCount:)` で算出**（表示ロジックの単一管理）。`MenuBarLabel` は `headline(...)` で得た `presentation` の `isSyncing` / `menuBarIconName`（syncing 中は `MenuBarPresentation.syncFrameName(_:)`）を引くだけ。
- **【重要・ハング回避】`MenuBarExtra` のラベルに `TimelineView(.animation)` を置いてはならない**。その文脈では `minimumInterval` が無視され、SwiftUI が `MenuBarExtraHost.requestUpdate(after:)` を実質ゼロ間隔で再発火し続け、毎フレーム `NSStatusItem` の画像差し替え＋Auto Layout 再計算でメインスレッドが 100% スピン→アプリ全体が無応答になる（2026-06-18 実機で再現・サンプル採取で確定）。フレーム送りは **`.task(id: isSyncing)` 内の自前タイマー（`Task.sleep`）で `@State` の `animationFrame` を進め `Image(MenuBarPresentation.syncFrameName(animationFrame))` を差し替える**方式にする。`isSyncing` が落ちている間は `.task` がキャンセルされタイマーが回らず CPU を消費しない。実装は `Tide/App/TideApp.swift` の `MenuBarLabel`。CLAUDE.md §3「SwiftUI 起き上がり」にも load-bearing ルールとして記載。
- **アプリアイコン（`AppIcon`）も同テーマで差し替え**。mac 用 10 スロット（16/32/128/256/512 の 1x/2x）を `icon_*.png` 実体 + `Contents.json` の `filename` 紐付けで充填。

### 通知（UserNotifications・M4・2026-06-15）

- **発火は「ユーザの介入が要る／取りこぼし（未バックアップ）が起きうる確定的な事象」だけに絞る**（4 種）: ① 競合コピー作成（`reconcileRemoteEntry` の `.conflictThenDownload`）、② サイズ上限超過 `fileTooLarge`、③ リトライ give-up（`attempts >= 5`）、④ 不安定ファイル（`unstableFile` 警告・既に `unstableWarned` で dedup 済み）。**一過性エラー（network 等）は出さない**（オフラインのたびに通知が溢れるのを避ける＝本ファイル「構造化エラー」の `recentIssues` とは別ポリシー: recentIssues は全失敗を載せるが通知は確定事象だけ）。
- **配線は `SyncEngine`（@MainActor）の各点から fire-and-forget の `Task { await self.notifier?.post(...) }`**（PR #18 レビュー Medium）。`post` の初回呼びは許可プロンプト応答までサスペンドし得るため、インライン `await` だと確定エラー 1 件で以降のアップロード処理（特に `fileTooLarge` 分岐はキュー除去 Tx の直前）が宙吊りになる。通知は順序保証不要なので同期処理から切り離す（@MainActor 同士＋ path 値渡しで安全）。
- **判定は純粋関数 `NotificationPolicy.content(for:) -> NotificationContent`（`Tide/Core/NotificationPolicy.swift`）**。`NotificationEvent` enum（上記 4 種）→ `(identifier, title, body)`。**identifier は `"<種別>:<path>"`**（例 `conflict:a/b.txt`）で、UNUserNotificationCenter の「同一 identifier は置換」仕様により同一 (path, 種別) の連発を 1 件に畳む（バナー溢れ防止）。本文はフルパスでなく**末尾コンポーネント**（通知は幅が狭い）。全分岐 `NotificationPolicyTests`（identifier の安定性 / path・種別での分離 / 本文がファイル名を含む）。表示文言は xcstrings（`%@` 一個・`extractionState:"manual"`）。
- **発行と OS 連携は `NotificationManager`（`Tide/App/NotificationManager.swift`・@MainActor・`SyncNotifying` 実装）**。SyncEngine には `SyncNotifying`（`NotificationPolicy.swift` 定義）だけ注入し、UserNotifications / AppKit を持ち込まない（テストでも nil 差し替え可・既存 SyncEngine 直構築は AppEnvironment 1 箇所のみ）。`AppEnvironment` が 1 インスタンス保持し `notifier:` で SyncEngine へ注入。
- **許可（authorization）は初回 `post` 時に一度だけリクエスト**（起動時・セットアップ時には出さない＝エラー/競合が一度も起きないユーザにいきなりプロンプトしない）。許可されていなければ静かに諦める。Settings の「Notifications」トグル（`ConfigStore.notificationsEnabled`・**既定 on**・presence 判定）が off なら許可も求めない。`factoryReset` で消える設定群にも追加済み。
- **初回リクエストは単一タスク `authorizationRequest: Task<Void, Never>?` に集約**（PR #18 レビュー Low）。並行 post はこのタスクの完了を `await` してから `notificationSettings()` を読むので、初回プロンプト応答待ち中に来た 2 件目が `.notDetermined` で early-return＝取りこぼされない。許可状態は毎回読む（後から System Settings で許可された場合も拾う）。`requestAuthorization` は `.notDetermined` のときだけプロンプトを出し確定済みなら即返る。
- **通知クリックで Sync Activity を開く**: `NotificationManager.openActivity` クロージャを App 層が登録する（`openWindow` は SwiftUI の View 環境にしか無く AppKit デリゲートから直接呼べないため）。登録は **MenuBarExtra のラベル（`MenuBarLabel`・常駐アプリでは起動直後に必ず生成される）の `onAppear`** が一次、`MenuBarContent.task` が保険。クリック時も `openWindow` 前に `NSApp.activate`（LSUIElement の定石）。デリゲート登録は `AppDelegate.applicationDidFinishLaunching` で `registerAsDelegate()`。
- **据え置き**: file 名（末尾コンポーネント）が OS 通知本文＝ロック画面等に出うる（メタデータ露出）。バックアップツールとして「どのファイルか」を伝えるのが通知の目的なので by-design・トグル + OS 許可でゲート・**生エラー文字列は通知に出さない**（`SyncIssue.rawDetail` は通知に載せない）。`security/README.md` に注記。**実機受け入れ消化済み（✅ 2026-06-16・対話形式・チェックリストは運用どおり削除）**: ① 競合バナー（同期済みファイルを `chmod 000` → `.unreadable` → `.conflictThenDownload` で単一マシン再現）、② fileTooLarge バナー（1GiB 超スパースで誘発・FD `fstat` のみで本体未読のまま弾く）、③ バナークリック → Sync Activity 起動、④ トグル off で抑止（許可プロンプトも出ない＝`post` 冒頭ガードが `authorizationRequest` の前で return）、⑤ 初回許可プロンプト（OFF→ON 後の最初の確定事象で 1 回）を実機確認。give-up / unstable バナーは `NotificationPolicyTests` + 同一 `notifier?.post` 経路で担保しライブ確認は省略（divert と同じ判断）。**消化中に `ConflictNamer` のタイムスタンプ書式バグを発見し修正**（→ §3「競合ファイル命名」の注記）。
- **将来の 5 種目候補（PR #18 レビュー・スコープ外メモ）**: `applyRemoteDeletion` の `.keepLocalRemoteDeleted`（リモート削除だがローカル編集で残した＝ユーザ判断が要る）も通知候補。現状 sync_log warning のみで通知はしない。今回 4 種に絞る判断は妥当だが、将来の通知拡張時に検討。

### reconcile 入口の stat ゲート（M4 perf・pull コスト削減・2026-06-16）

- **問題**: `SyncEngine.performRemotePull` → `reconcileRemoteEntry` は remoteMap の全 entry を処理するが、未変化シャードの entry は `ManifestReader` が DB レコードそのものから再合成する（sha/etag/versionId/size/mtime 全部 DB 由来）。よって steady-state では「ローカル == DB == リモート」なのに**毎 pull（最短 3 分毎）に全ファイルを 2 回 hash（`ThreeWayMerge` 用 + `download()` 早期 return 用）＋ 全行 DB write**。さらに reconcile は `@MainActor` 上で hash していた（`processEventToQueue` だけ `Task.detached` で逃がしていた）＝pull 中のメインスレッドブロック。
- **修正（3 点）**:
  1. **stat ゲート**: reconcile 入口で純粋関数 **`ChangeDetector.reconcileIsNoop`** を呼ぶ。`preDecision == .skip`（ローカル stat == DB の size/mtime）かつ DB が entry を**そのまま反映**（`DB.sha == entry.sha256 && (DB.s3Etag ?? "") == entry.etag && DB.s3VersionId == entry.s3VersionId`）なら、`markSynced` が書く値と timestamp（`lastSyncedAt`/`updatedAt`）以外完全一致するので**証明可能な no-op**としてスキップ（hash も DB write もしない）。timestamp の bump 省略は無害: 再合成マニフェストの `uploadedAt` に使われるだけで、再合成は read 専用＝S3 に戻らず比較対象にもならない（むしろ「最後にアップロードした時刻」として正しい）。
  2. **`.localMatchesRemote` を `download()` から分離**: ゲートを抜けた `.localMatchesRemote`（= 実際に mtime ドリフト / etag ドリフトの修復が要るケースだけ残る）は専用 **`Downloader.markSynced`**（= 旧 `updateDBEntryWithoutWrite`）へ。`download()` 内の二度目 hash（`currentLocalSha`）を排除。`.download` / `.conflictThenDownload` は従来どおり `download()`（早期 return の安全網は温存）。
  3. **残る hash を off-main 化**: ゲートを抜けて hash が要るケースの `HashCalculator.sha256` を `Task.detached(priority:.utility)` へ（`processEventToQueue` と同パターン）＝pull 中のメインブロック解消。
- **ゲートの厳密さ = 厳密版（no-op 証明可能）を採用**（会話で確定）。クロスデバイスで同一内容が再 UL され etag だけ変わった場合はゲートが外れ、通常経路の hash → `.localMatchesRemote` → `markSynced` で DB の etag/versionId が最新化される（より正しい方向）。**S3 マニフェストは Uploader しか書かない**ので、ゲートで etag/versionId 更新を省いても S3 汚染の経路は無い（再合成は read 専用）。
- **安全性**: ゲートは `preDecision`（既存の SHA ゲートと同じ「size+mtime 一致 → 内容不変とみなす」前提）を流用＝`performFullScan` と同じ accepted な前提を継承し新たな取りこぼし窓を作らない。`localRec.sha256 != entry.sha256`（リモート変化）/ size or mtime ドリフト / 未追跡 のいずれでもゲートは外れ通常経路へ落ちる。`ChangeDetectorTests` の `reconcileIsNoop` 群で全分岐固定（一致 → no-op / sha・etag・versionId 差 / size・mtime 差 / known nil / 未同期 / 空 etag + nil versionId）。配線（reconcile → I/O）の結合テストは docs/09 の scan/event 配線と同じく未整備のまま据え置き。
- **実機受け入れ消化済み（✅ 2026-06-16・対話形式・チェックリストは運用どおり削除）**: 観測信号は `files.updated_at`（pull のたびに reconcile が全行 DB write すれば bump される）。**BEFORE**＝変更前ビルド（旧 running app）が、内容無変更のまま poll のたびに全 3 ファイルの updated_at を bump（03:28:48→03:31:49→03:34:51・180s 間隔）し、しかも `.syncignore` の shard は再 fetch されていない（etag キャッシュ）のに updated_at が進む＝再合成 entry でも全行 write する無駄を実機確認。**AFTER**＝新ビルド（PR）に差し替えると、起動 pull・周期 poll を跨いでも updated_at 凍結（ゲート発火＝write 無し・余計な sync_log 無し）。**実変更の往復**＝`perf-b.txt` を編集→新ビルドがアップロード（DB/S3/sha 更新）→ 次 poll で **shard 46 が S3 から再 fetch された**のに perf-b の updated_at は進まず（DB 再合成 entry だけでなく S3 から取り直した生 entry に対してもゲートが正しく no-op 化・再 UL ループ無し）。pull の `.download`/`.conflictThenDownload` 分岐は本 PR で不変（同一 `dl.download()`・`DownloaderTests` + reviewer 解析で担保）なため move-out による live `.download` 検証は不採用（起動時 `performFullScan` の missing→削除キュー投入が pull の再 DL と競合し S3 削除を伝播しうるため）。bucket `dev-tide` / sync root `/Users/hige/Tide` で実施、後始末でテストファイルを削除し S3/DB を元状態へ復元。

### バージョン単一化と診断エクスポート（2026-06-19・PR #24）

- **バージョン単一ソース化**: `Tide/Info.plist` の `CFBundleShortVersionString` / `CFBundleVersion` を `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 参照にし、**バージョンは `project.yml` の build settings を唯一のソース**にした（plist 側に数値を二重定義しない・Xcode がビルド時に展開）。あわせて `NSHumanReadableCopyright` を設定、`LSApplicationCategoryType=utilities` を追加（アーカイブ時のカテゴリ未設定警告を解消）。About 表示・診断テキストはどちらも `Bundle.main` から動的取得するのでこの単一ソースに追従する。
- **About のアプリアイコン**: `NSImage(named: "AppIcon")`（バンドルのコンパイル済み asset catalog を直接引く）を一次ソースにし、解決できないときだけ `NSApp.applicationIconImage` にフォールバックする。**`NSApp.applicationIconImage` は LaunchServices のアイコンキャッシュ（バンドル ID 単位で古い dev ビルドのアイコンを保持しがち）を反映して古い絵を返すことがある**ため、現在のバンドルのアイコンを確実に出すには named 参照が要る（実機で旧アイコン表示を確認・差し替え済み）。`AboutWindowTests` が appiconset `"AppIcon"` の `NSImage(named:)` 解決を担保（`MenuBarPresentationTests` のアセット実在テストと同じ「無言の空画像」防止）。
- **診断エクスポート**（`Tide/Core/DiagnosticsExporter.swift`）: サポート用に診断テキスト + `sync-log.txt` + DB スナップショットを 1 つの `.zip` にまとめ、`NSSavePanel` でユーザが選んだ場所へ書き出す。
  - **セキュリティ境界（`security/low.md` L13）**: AWS 認証情報（Keychain）は一切扱わない（構造的に漏れない）。ただし DB スナップショットと sync_log には**ファイル名/相対パス・バケット名・deviceId が含まれる**ため、「含む/含まない」を Settings 文言と `diagnostics.txt` の Note に明示する（生成物を第三者へ送る前提のため・CLAUDE.md の path 非公開方針と整合）。
  - **DB スナップショット**: `LocalDatabase.snapshot(to:)` が `VACUUM main INTO ?`（`writeWithoutTransaction`＝VACUUM はトランザクション内不可）で WAL を取り込んだ一貫単一ファイルを出力。出力先は事前非存在であること。
  - **メインスレッドを塞がない**: env からの値収集だけ `@MainActor`（`export`）で行い、log 取得・staging 書き出し・スナップショット・zip 化は `nonisolated` の `writeArchive` に分離してメインアクター外で実行（CLAUDE.md「重い処理はメインから外す」）。
  - **純粋関数 + 結合テスト**: `diagnosticsText` / `logText` は純粋関数（`DiagnosticsExporterTests` がシークレット非混入を含め固定）。`writeArchive` は temp DB + サンプル入力で「zip が生成され diagnostics.txt / sync-log.txt / db.sqlite を含む」ことを結合テストで固定。zip 展開時の最上位フォルダ名は `Tide-Diagnostics`（UUID は親 temp 側に付ける）。
