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
- **stale UploadId 回復（Issue #33、2026-06-25）**: 再開時に死んだ UploadId（前回 complete 済み→`clearUpload` 前にクラッシュ／7 日ライフサイクル失効）は `NoSuchUpload` で空振りする。`S3ErrorClassifier.isNoSuchUpload(_:)` を新設し、`MultipartUploader.upload()` の complete を inner do/catch で包む。**complete が `NoSuchUpload`** なら `headObject(key:)` で本体を確認し、**存在 & `head.size == bytesRead`（読了総バイト＝完成オブジェクトサイズ）一致なら identity（etag/versionId）を回収して成功扱い**（checkpoint クリア）。回収不能（本体なし/サイズ不一致＝MPU が本当に失われた）は checkpoint を破棄して rethrow＝次回フル再開（新規 `createMultipartUpload`）に委ねる。**併せて経路2**: `uploadPart` が `NoSuchUpload`（失効 MPU）になった場合も、旧挙動の外側 catch は checkpoint を保持して死んだ UploadId を毎周回再開し続け**そのファイルは変更されるまで永久に上がらなかった**ため、外側 catch に `isNoSuchUpload` 分岐を足して checkpoint を破棄しフル再開に委ねる。回収オブジェクトの同一性は `head.size == bytesRead` + 後段マニフェスト RMW（`ThreeWayMerge.decideUpload`）の競合検出が二重防壁。`headObject` は `MultipartUploadClient` シームに追加（`TideS3Client` は既存メソッドで適合）。検証は fake 主体（`MultipartUploaderTests` の complete 回収/回収不能/uploadPart 失効 3 ケース + `S3ErrorClassifierTests`）。NB: `NoSuchUpload` は HTTP 404 で返るため `isNotFound` とも一致し得るので、再開専用にコード文字列で明示判定する。
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
- **`AppEnvironment.factoryReset` は「アプリから届く範囲で」`make reset` に揃える**: App Group コンテナ（DB）/ コンテナ内 Caches（tmp・削除一覧キャッシュ）/ UserDefaults（group suite + standard＝コンテナ側 plist）/ Keychain を消す。deviceId も含めて消す（`ConfigStore.resetIncludingDeviceId`）。**sandbox 下では実ホームの旧ロケーション残置分（移行元 `db.sqlite`・旧 Caches）には届かない** — 旧残置分の完全削除は `make reset`（sandbox 外）でのみ可能（PR #49 レビュー #5）。standard defaults も消すのは、OS がサンドボックス初回起動時に旧 preferences plist をコンテナへ自動移行してくるため（残しても設定移行は legacy DB 実在ゲートで発火しないが、判定材料を残さない多層防御）。

### App Group への状態移設（M5 Phase 2〜3）
- **置き場所**: DB は `TideAppGroup.supportDirectoryURL()`（group container 内 `Library/Application Support/Tide/`）、設定は group suite の UserDefaults（`TideAppGroup.sharedDefaults()`）、Keychain は従来の access group（`$(AppIdentifierPrefix)org.izukawa.Tide`）を `kSecAttrAccessGroup` で明示。`TideFileProvider` 拡張が同じ 3 点を共有する。
- **App Group ID はチーム ID プレフィックス形式**（`G5G54TCH8W.org.izukawa.Tide`・Phase 3 で切替）: `group.` 形式は macOS では TCC 保護され、provisioning profile の正式許可が無い場合、対話 UI を持つアプリは同意フローで通る一方、**UI の無い拡張プロセスは containermanagerd に問答無用で拒否される**（Phase 3 実機で File Provider 拡張の group defaults が空になり notAuthenticated を返し続けた実害。containermanagerd ログ "Group containers identifiers should be prefixed by requestor's team ID" が根拠）。チーム ID プレフィックスなら署名のチーム一致だけでアクセス可能＝Portal / プロファイル依存ゼロ。Phase 2 の一時 ID `group.org.izukawa.Tide` は移行元としてアプリ側 entitlement にのみ残す（移行期間後に外してよい）。移行元は「旧 group コンテナ → 実ホーム」の新しい順に試す（`LegacyStateMigrator.migrateIfNeeded(legacySources:)` の連鎖・冪等ゲートで先勝ち）。
- **一度きり移行 = `LegacyStateMigrator`**: bootstrap 冒頭（`setupCompleted` 判定より前）で冪等に実行。DB は「group 側本体 db.sqlite の有無」、設定は「**legacy DB が実在し group 側に揃っている** ∧ group 側 `setupCompleted` キー無し ∧ 旧側セットアップ完了」で要否判定。DB コピーは WAL/SHM → 本体の順（本体の有無が冪等キーなので途中クラッシュから頭やり直しできる）、失敗時は部分コピーを消し**設定移行ごとスキップ**して次回再試行（設定だけ先に移すと launchEngine が空 DB を生成して冪等キーを汚し、DB 移行リトライが永久に潰れる — PR #49 レビュー #4）。旧ファイル・旧キーは温存（データ損失 < 重複）。
- **2 段コミット移行戦略**: 移行コードは App Sandbox ON より前のビルドに入れて一度起動する（旧パスが読めるうちに移行）。Sandbox ON 後は旧 DB がコンテナ内に解決されて見えなくなる。**注意: 旧 preferences plist は macOS がサンドボックス初回起動時にコンテナへ自動移行（move）するため「旧設定だけは見える」**（PR #49 レビュー #1・実機検証済み）。設定移行を legacy DB 実在でゲートしているのはこのため — さもないと中間ビルドを飛ばした環境が「設定あり・DB 空」で起動し、全ファイル未追跡の全量再アップロード・競合コピー量産・ローカル削除済みファイルのリモートからの復活を起こす。ゲートにより一足飛び経路は全体として no-op（新規状態＝ウィザード再設定）に落ちる。
- **同期フォルダのリネーム/移動追跡**: bookmark はファイル ID で追跡するため解決後の URL は新パスを返す。`resolveSyncRootAccess` は解決成功を「同一フォルダ」とみなし `syncRootPath` を新パスへ追随更新する（パス等値で拒否すると Finder のリネームだけで「満たせない再許可パネル」が毎起動出続ける — PR #49 レビュー #2）。再許可パネルの受け入れ判定も文字列等値ではなく `PathValidator.isSameFileSystemObject`（volume + file id）で行う。

### App Sandbox / security-scoped bookmark（M5 Phase 2・security L1）
- **entitlements**: `com.apple.security.app-sandbox` + `files.user-selected.read-write`（powerbox パネル）+ `network.client`（aws-sdk-swift）。File Provider 拡張（Phase 3〜）はサンドボックス必須なので app 側で先に整えた。
- **同期フォルダのアクセス権 = `ConfigStore.syncRootBookmark`**（security-scoped bookmark）。**v0.3.0 #97 以降、新規セットアップは bookmark を発行しない**（`completeSetup` から発行・書込を削除 = fpOnly に syncRoot 面が無い。以下は folderSync 世代の記録 → 現行は「ウィザード fpOnly ネイティブ化」節）。旧: 発行はセットアップ確定時（`AppEnvironment.completeSetup`。**setupCompleted を立てる前に**発行し、手入力パス等で権限が無ければ確定前に失敗させる）。解決は `resolveSyncRootAccess`（launchEngine の入口。存在チェックより前＝アクセス確立後でないと fileExists 自体が成立しない。folderSync デッド経路として温存）。stale なら再発行。アクセスはメニューバー常駐の生存中ずっと保持（stopAccessing はフォルダ変更時のみ）。
- **bookmark 欠落/失効時の再許可**: 起動時に `requestSyncRootAccessViaPanel` が NSOpenPanel（現行フォルダを初期位置・説明メッセージ付き）を一度だけ出す。キャンセルは bootstrapFailure（ポップオーバー再表示で bootstrap 経由の再試行）。**設定済みパスと不一致のフォルダ選択は拒否**する — 別フォルダを黙って受けると既存 DB との突き合わせで大量の「ローカル削除」誤検出（＝リモート削除の伝播）を起こしうるため。
- **Caches の移設は暗黙**: `TideTmpDirectory` / `DeletedFilesCache` は `.cachesDirectory` 相対のままサンドボックスのコンテナ内へ自然に移る（中断転送の `.part` は失われるが Range 再開が頭からやり直すだけ・削除一覧キャッシュは再列挙で再生成）。

### File Provider 読み取り PoC（M5 Phase 3）
- **拡張は DB に一切触らない**: 列挙はマニフェスト直読みの `ManifestSnapshotLoader`（index + 全シャード・shard_state キャッシュ無し・書込ゼロ）→ `ManifestTree` で path→ツリー合成。2 プロセス DB 書込競合を構造で回避する（Phase 5 は「拡張 = 第 3 のデバイス」方式＝DB 非接触のまま S3 へ直接書く。旧「単一書き手＝拡張への移行」構想は撤回）。
- **`fetchContents` はマニフェストの `s3VersionId` に固定して取得**し、commit 前にサイズ + SHA-256 を検証（Downloader と同じ不変条件）。列挙と取得の間に最新版が変わっても提示済み itemVersion と中身が食い違わない。
- **書込系（create/modify/delete）は全拒否**（read-only PoC）。item capabilities も read のみ。
- **item identifier は `p:` + 相対 POSIX パス**（ルートは `.rootContainer`。**M5 Phase 5-1 で `f:`/`d:` の kind 織り込み形式へ変更** — 下記 Phase 4 節の「item identifier の kind 織り込み」項参照）。プレフィックス無しの生パスだと、予約 identifier（`NSFileProviderRootContainerItemIdentifier` 等の rawValue）と同名のファイルパスが衝突して階層破綻・永久 noSuchItem を起こしうる（PR #50 レビュー #4）。
- **並列取得の骨格は `BoundedParallel.compactMap`**（TideCore 共有ヘルパ）に一元化。`group.next()` 結果の取りこぼし罠（下記）を構造的に封じる。
- **並列 TaskGroup の結果回収**: 同時実行上限に達した時に消費する `group.next()` の結果を `_ =` で捨てない（シャード数 > 上限で完了分が黙って失われ「無エラーでファイル欠落」になる。Phase 3 実機で 15 中 6 件欠落として顕在化。`ManifestReader` にも同型の潜在バグがあり両方修正 — 本体側は「未変更シャードの DB 補完」が欠落をマスクしつつ shard_state 未更新の再取得を毎周回発生させていた）。
- **拡張のログは既定レベル以上（notice/error）で出す**: `.info` は永続化されず `log show` で追えない。拡張プロセスは対話デバッグしづらいため、設定チェック等の診断は notice 以上に（`log stream` はリダイレクトでバッファされるので `script -q` 経由の pty で取る）。
- **拡張の Info.plist 必須キー**: `NSExtension` 配下に `NSExtensionFileProviderDocumentGroup`（App Group 指定）と `NSExtensionFileProviderSupportsEnumeration`。欠けると `NSFileProviderManager.add` が `-2014 applicationExtensionNotFound`。初回はシステム設定（ログイン項目と機能拡張 → ファイルプロバイダ）でユーザが拡張を有効化する必要がある（それまでドメインは `user-disabled`）。

### File Provider 増分列挙 + リモート追従（M5 Phase 4・2026-07-04）
- **世代モデル**: マニフェストのスナップショットを「世代」として扱い、`NSFileProviderSyncAnchor` = 世代 ID（UUID 文字列。**anchor は 500 バイト上限**＝SDK 明文）。直近 8 世代のファイルマップを `ManifestGenerationLog`（App Group コンテナ内 `Library/Caches/Tide/fileprovider-manifest-log.json`・bucket-keyed・atomic 書出）に永続化し、`enumerateChanges(from:)` は「anchor の世代 → 現在」を `ManifestTreeDiff` で didUpdate / didDeleteItems へ写像する。**未知/世代落ち anchor は `.syncAnchorExpired`** → システムがキャッシュを破棄して全再列挙（自己回復。ログ消失・bucket 変更・Phase 3 の静的 anchor もこの経路で吸収＝ドメイン作り直し不要）。同一内容のリフレッシュは世代を増やさない（anchor 安定・shard etag と取得時刻のみ更新）。
- **増分ロード**: `ManifestSnapshotLoader.load(previous:)` が index の shard etag 差分で変化したシャードだけ GET し、無変化シャードは前回世代から持ち越す（etag の意味論 = `ManifestReader` の shard_state と同一。比較は index 宣言値・記録は取得オブジェクトの実 etag・404 レースは未記録で次回再取得）。**DB 非接触の不変条件は維持**（世代ログは拡張専用 JSON。書き手は拡張プロセスの `ManifestGenerationCache` アクターのみ）。
- **working set = ドメイン全 item**（FruitBasket 方式）: macOS の replicated 拡張では**リモート変更がシステムへ届く唯一の経路が working set の `enumerateChanges`**。個別コンテナへの signal は**無視される**（SDK ヘッダ明文）ため、working set を空のままにすると列挙済みレプリカが恒久 stale になる。`currentSyncAnchor` は「その enumerator が最後に提示したツリーの anchor」を返す（提示内容と anchor がずれると diff の取りこぼし窓ができる）。
- **リモート追従の通知（折衷案・2026-07-04 ユーザ確定）**: ①主経路 = **アプリ側**。`SyncEngine.performRemotePull` がシャード変化を取り込んだ後と、アップロード/削除で**マニフェストが実際に書かれた確定点**に `FileProviderController.signalRemoteChanges()`（= `signalEnumerator(.workingSet)`・未登録 no-op・fire-and-forget）。アップロード側の発火点は M5 Phase 5-0 でバッチ集約（`anySucceeded`）から `ManifestUpdater.onManifestDidWrite`（`putShard`+`updateIndex` 成功直後）へ移設し、PR #51 レビュー #4 の「マニフェスト PUT 成功 → DB write throw で 1 バッチ分 signal が漏れる」窓を構造的に解消した。`.alreadyUpToDate`（書いていない）・`.conflict`・412 リトライ尽き・no-op 書換（マニフェスト不在パスへの delete 等＝書かない）は非発火 — **ただし下記の index 突合修復として書いた場合はその修復分だけ発火する**（`.alreadyUpToDate`/`.conflict`/no-op 経路でも修復書込は可視化の確定点。PR #56 再々レビュー (d) で節内矛盾を解消）。**putShard 成功 → updateIndex リトライ尽きは非発火のまま失敗として伝播**し、キュー再試行の `.alreadyUpToDate` / no-op 再入が「シャード実 etag と index 宣言」を突合して **index のみ修復 + 発火**する（PR #56 レビュー ①: 旧実装はこの分断で、外側 RMW リトライが自前 `manifestUpdateFailed` の文字列を 412 と誤分類 → 再実行が `.alreadyUpToDate` 短絡 →「index が旧 etag を宣言し続け全読者から恒久不可視」の静かな成功に化ける既存バグがあった。対処 = `withConditionalRetry` は SyncError を素通し + 再入時の index 突合修復。同型の文字列誤分類は path に "412" を含む `uploadConflict` でも起き得たため素通しで一括遮断）。**突合修復は CAS 付き**（観測した宣言から index が動いていたら修復中止＝並行書き手の新しい宣言を stale 観測で巻き戻さない/除去しない。特に dangling 宣言の無条件除去は、観測とコミットの間に別書き手が同シャードを再作成していた場合に「実在シャードが未宣言」= removedShards 誤検出 → 削除伝播へ化けるため CAS が必須。`.conflict` throw の直前にも同じ修復を通す＝「updateIndex 分断 → backoff 中の再編集 → 幻影競合」の連鎖でも stale を持ち越さない。PR #56 再レビュー (1)(3)、レースは `InMemoryManifestStore` の観測直後書換注入で回帰固定）。削除伝播クラスの残余窓 2 つも閉鎖（再々レビュー (a)(b)）: dangling 宣言の除去はコミット前に**シャード実在を再確認**（観測前の 1 リクエスト間隙に並行再作成が完了していても中止）、空シャード削除の**主経路**の宣言除去も「自分が消したシャードの観測 etag を宣言しているとき」のみの CAS（deleteShard〜index コミット間の並行再作成 + 宣言を消さない）。主経路 CAS のガード失敗時は**実在再確認付き dangling 除去へフォールスルー**（第 4 ラウンド (g): 失敗理由が「先行分断の stale 宣言」だった場合、主系は成功でキュー行を消すため再入が来ず、宣言が dangling のまま削除が伝播しない ghost 化になる。実在すれば何もしない = 並行再作成の温存と両立）。dangling 除去は `removeDanglingDeclarationIfShardAbsent` ヘルパに集約。signal はアプリ側 `FileProviderController.signalRemoteChanges` でコアレス（即時 1 発 + 1s クールダウン + トレーリング 1 発。per-item 発火の XPC 増幅対策 = レビュー ③）。`ManifestUpdater` は書き先を `ManifestStore` プロトコル（`ManifestSnapshotSource` の refinement・`InMemoryManifestStore` フェイクで楽観ロック込み全分岐を `ManifestUpdaterTests` が回帰固定）へ抽象化し、Uploader が init で 1 個だけ構築して upload/delete が共用する（hook 配線点の一箇所化 = レビュー ④）。アプリは既に S3 を定期 pull しているので**追加の S3 GET コストゼロ**。②補完 = **拡張の機会的自己 signal**。ブラウズ契機のキャッシュリフレッシュが新世代（= リモート変化）に気づいたら `onNewGeneration` → 自己 signal（タイマー無し。signal → enumerateChanges → 直近ロードで新世代なし → 再発火しない＝収束）。**拡張内タイマーポーリングは不採用**（拡張は OS が随時 kill するため信頼性が低く、S3 GET がアプリの pull と二重になる）。`enumerateChanges` 応答は TTL を待たない `refreshedCurrent()`（下限間隔 2s でバースト吸収）— signal 直後の enumerateChanges が TTL キャッシュを読んで「変更なし」を返すと、その変化が次の signal まで届かなくなるため。
- **ディレクトリの合成 mtime**: `ManifestTree` が配下ファイルの最大 mtime をディレクトリへ畳み込み（Finder の 1970 表示解消）、metadataVersion にも載せて配下更新で表示日付が追従する。**ルートは常に nil**（`item(for:)` の root 高速パスがマニフェスト非依存のため、経路によって root の itemVersion が揺れないよう固定）。
- **item identifier の kind 織り込みと種別変化の配信（M5 Phase 5-1・2026-07-06）**: item identifier を `p:<path>` から **`f:<path>`（ファイル）/ `d:<path>`（ディレクトリ）** へ変更した。動機 = fileproviderd は**同一 id の kind（file⇄dir）変化を受理しない**: update 単発は `itemKindMismatch` 拒否（ゾンビ化・2026-07-05 実機）、delete+update の分解配信も ① 単一レスポンス内 ② moreComing ページ分割 ③ 中間 anchor 確定 + 自己 signal の別セッション（22ms 差）の **3 形態すべてで「item changed」の ingest 合成により delete が update を打ち消す**（item 消失。2026-07-06 実機。①②は即時合成、③はタイミング依存 — file→dir が 9ms 差で通った例もあるが本番不適）。kind ごとに id を分ければ kind 変化 =「旧 id の delete + 新 id の出現」= 独立した 2 変化となり、合成の余地が構造的に消える。`ManifestTreeDiff.Changes` は `deleted` を**旧ツリーのノード**（kind 情報付き）で返し、enumerator が旧 id を正しく組む。種別変化は didDeleteItems（旧 id）→ didUpdate（新 id）を**単一セッション**で配信して収束する（強制単一世代 = 拡張 STOP/CONT で file→dir / dir→file / materialize 済みの 3 方向を実機受け入れ）。**移行**: 旧 `p:` ドメインは Disable → Enable で作り直し（`.syncAnchorExpired` 全再列挙による無再作成移行は不可 — 旧 id item が名前衝突で「名前 2」リネームされ恒久残存する。`docs/09` 既知の癖参照）。
- **CloudStorage フォルダ名は変更不可（調査結論・2026-07-04）**: `~/Library/CloudStorage/<ホストアプリ表示名>-<domain.displayName>` はシステム（fileproviderd）が合成し、制御する API は無い（Tide は "Tide-Tide"）。ただし **Finder 上の表示名は既に「Tide」に解決済み**（実測）で、ハイフン名が露出するのは POSIX パスのみ。Dropbox も実フォルダは "Dropbox - Personal" 形式。→ 現状維持で確定（据え置きにしない）。なお同一 identifier のドメインは再 add でプロパティ更新可（remove 不要・SDK ヘッダ明記）。

### FP 双方向書込（M5 Phase 5-2〜5-3・「拡張 = 第 3 のデバイス」方式・2026-07-06 / 2026-07-09）

FP ドメイン内のファイル編集（`modifyItem` の .contents）と削除（`deleteItem`）= Phase 5-2、
新規作成（`createItem`）+ ディレクトリ再帰削除 + dir メタデータ受理 = Phase 5-3 を実装した
（改名/移動 = 5-4 のみ残）。設計と不変条件:

- **書込境界**: 拡張は **S3 とマニフェスト（+ 自世代ログ）だけを書く**（`ExtensionWriter`）。アプリの DB / syncRoot / tmp には一切触れない ＝ [pull/restore 直列化] と [mtime 不変条件] に影響しない。アプリは既存 pull で拡張の書込に追従する（**アプリ側コード変更ゼロ**・2 台目 Mac と同型）。
- **共有チョークポイント**: マニフェスト書込はアプリと同一の `ManifestUpdater` を通す。3-way ベースは FP の `baseVersion`（itemVersion = sha256）から `FileProviderWritePolicy.baseSha` で取得（**DB 非接触のまま競合検出できる**理由）。並行更新は If-Match RMW + `decideUpload` / ベースガードが裁く。
- **deleteItem**: `ManifestUpdater.removeFileEntry(for:base:)` 新設 — **ガードを RMW 内**に置き（チェック → 削除の間の並行更新窓を 412 リトライごとの再評価で閉じる）、ベース一致のみ除去。ベース不明（nil）も拒否側（「データ損失 < 重複」）。**順序 = マニフェスト除去 → deleteObject（marker）**＝アプリの processDelete と逆（権威判定点が RMW 内にあるため）。marker 発行失敗は削除成功扱い（真実 = マニフェストは除去済み・不可視 live は版履歴で回復可）。リモートがベースより進んでいたら `fileProviderErrorForRejectedDeletion(of: 最新item)` — **fileproviderd が受理し最新版を復元することを実機確認**（拡張プロセスの respawn を跨いでも機能）。
- **modifyItem 競合**: `.conflict` は FSEvents 側 `resolveUploadConflict` と対称 — ローカル編集を `ConflictNamer` の別 path へ上げ直し（tmp はコールバック中生存 = 再アップロード可）、completion は**リモート現行 entry の item + `shouldFetchContent=true`**（正規パスはリモート勝ち）。**受理・収束を実機確認**（正規 = リモート版 / copy = ローカル編集・データ損失ゼロ）。メタデータのみの modifyItem は黙って受理（remainingFields に残すと永久再試行）。
- **書込後のキャッシュ無効化 + stale ロード破棄（bounce 防止の要）**: 書込が **S3 に確定した後**に `ManifestGenerationCache.invalidateAfterLocalWrite()` を呼ぶ。**世代を局所構築せず**、`cached = nil`（次の `current()` は S3 から読み直す）+ `lastLocalWriteAt` 前進（書込前に開始した進行中ロードを stale 破棄）+ `onNewGeneration`（自己 signal）だけを行う。S3 が truth の単一の出所になり、completion で返した item（書いた entry から生成）と読み直し後の item は同一 itemVersion（sha256）= システム側の再適用は no-op = bounce しない。※初期実装の**局所世代構築（`recordLocalChange`）は撤去**（PR #58 レビュー #2/#3）— cold 時に他シャードを欠いた near-empty 世代を捏造して 30 秒配信し、温世代 + live etag では他デバイスの同シャード追加ファイルを恒久的に隠していたため。stale ロード破棄は `loadSnapshot` に開始時刻を task と束ねて持たせ（await 後の共有状態読みで開始時刻を取り違えない・レビュー #4）、閾値（`max(lastLocalWriteAt, minStartedAt)`）を満たすまで **while ループ**で読み直す（読み直し中の追加書込も取りこぼさない・レビュー #5）。single-flight のクリアは `if inflight?.task == task` の identity ガードで合流者の再ロードを握り潰さない（レビュー #6）。
- **signal の役割分担**: 拡張の `ManifestUpdater` は `onManifestDidWrite` を**明示 nil** — 拡張の anchor 前進は `invalidateAfterLocalWrite` → `onNewGeneration` → 自己 signal が一元的に担う（アプリ側は世代ログを持たないため書込確定点 hook が signal の正位置、という対比）。
- **セキュリティゲート**: identifier→path 変換直後の `validateRelativePath`・サイズ上限（`uploadSizeLimitBytes`）・**帯域上限（`uploadBandwidthBytesPerSec` の `RateLimiter`・アプリと同規約。拡張はループ無し短命なので構築時の値で固定**・レビュー #7）・SSE-S3（putObject/MPU 内で明示）・`NoFollowFileReader`（fileproviderd 提供 tmp は静止が契約だが多層防御）・conflict copy 名も `validateRelativePath` を通す。itemVersion の contentVersion 符号化と 3-way ベース復号は `FileProviderWritePolicy`（TideCore）に**対で同居**させ往復テストで固定（別モジュール分断による無言破壊を防ぐ・レビュー #8）。
- **実機受け入れ**（2026-07-06）: FP 編集 → pull で syncRoot 反映 / FP 削除 → 全デバイス削除 / 削除拒否 + 復元 / 編集競合の両方保持 / bounce ゼロ / sync_log エラー 0。既知の残余レース（redeclare 観測前窓・無条件 DELETE）は 5-2 設計時に再評価 — 拡張書込は同一チョークポイント経由のため**新しい窓は増えない**（従来どおり記録のまま）。

#### createItem / ディレクトリ削除（M5 Phase 5-3・2026-07-09）

- **createItem（ファイル）は「base nil の書込」**: 本体 upload → `ManifestUpdater.updateFileEntry(base: nil)`。`decideUpload(base: nil)` が三分岐を裁く — リモート不在 = 作成（`.proceed`）/ 同一 sha = 冪等（`.alreadyUpToDate`・mayAlreadyExist の再取り込みもここへ合流）/ 別内容 = 並行作成の衝突（`.conflict`）。衝突は modifyItem 競合と対称に **conflict copy へ上げ直し、作成 item を copy に束ねる**（ローカル実体 = copy の内容そのもの・再取得不要。正規パスのリモート版は次の enumerateChanges が新 item として配る = 正規パスはリモート勝ち・データ損失ゼロ）。`ExtensionWriter.modifyFileContents` を createItem と共用（`contentsURL: nil` = 内容なし作成 → 空ファイル PUT）。`NSFileProviderCreateItemDeletionConflicted`（working set 削除 vs ローカル編集）も同経路 — マニフェスト不在なら編集内容で再作成（pull 側 `keepLocalRemoteDeleted` と同じ側）。**root 孤児 UX（Phase 3 の既知の癖）はこれで解消** — 既存孤児も pending 再試行が createItem に到達した時点で取り込まれる。
- **パス合成の構造検証**: 親 dir id の path + `itemTemplate.filename` → `FileProviderWritePolicy.childPath`（空 / `.` / `..` / `/` 含み / NUL は nil）→ `PathValidator.validateRelativePath`。検証不能な名前（バックスラッシュ等）は `ExcludedFromSync` = ローカル温存・S3 非汚染（FSEvents モードが検証不能パスを同期しないのと同じ側）。
- **除外 = `NSFileProviderError(.excludedFromSync)`**（SDK 正規の意味論 = **ローカルに残して同期しない** + メタデータ変化時に再評価の createItem が来る。FSEvents モードの「除外はローカル温存」と完全対称）: ① 機密網 `HardcodedIgnoreRules`（ファイル + **ディレクトリは subtree ごと**単発拒否 = スキャンの機密網 dir `skipDescendants` と対称）② symlink（同期しない不変条件の FP 側適用）③ ユーザ `.syncignore`（未追跡のみ・`.syncignore` 自身は除外しない = FSEvents と同一の `IgnoreDecision.shouldSkip`）。**ユーザパターンの dir 単位除外は意図的にしない** — `!` 再包含（同層否定）の意味論は per-file 評価が担う（スキャン側も dir prune はハードコード網のみ）。
- **`.syncignore` の FP 適用 = `ManifestIgnoreCache`**（TideCore・案 B = FSEvents モードと同挙動・2026-07-09 ユーザ確定）: 拡張にはローカルフォルダが無いので、真実 = マニフェスト宣言の同期済み `.syncignore` 群（= アプリが pull 後にローカルで読むもの）。世代アンカーをキーに `LayeredSyncIgnore` をキャッシュ（single-flight 合流）+ **(path, sha) メモ化**で世代が進んでも不変の `.syncignore` は再取得しない（定常コスト実質ゼロ）。取得は versionId 固定 + 全バイト SHA-256 検証（改ざんされた層構成で除外判定しない）・pinned 消失は最新版フォールバック・両振りは層スキップ（除外しない安全側）・`maxFiles` 打ち切りは浅い層優先。fetch 失敗は throw = createItem が一時エラーで再試行（アップロード自体に S3 が要るので可用性は悪化しない）。回帰は `ManifestIgnoreCacheTests`。
- **空フォルダ = ローカル仮想受理**（S3 非接触・2026-07-09 ユーザ確定）: マニフェストにディレクトリエントリは無い（dir はファイルパスから合成）ため、フォルダ createItem は何も書かずに成功で返す。配下にファイルが入った時点で合成 dir として実体化・同期される。空のままなら他デバイスへ伝播せず、ドメイン作り直しで消える（FSEvents モードの「空ディレクトリは同期しない」と整合）。`d:<path>` の path 決定的 id により仮想フォルダと実体化後の合成 dir は同一 item に収束。**支持配線**: `item(for:)` はマニフェスト外の dir id に合成 dir を返して温存（noSuchItem を返すとデーモンがローカルフォルダごと掃除する。kind 不一致 = 実体がファイルの場合は従来どおり noSuchItem = 5-1 意味論維持）、enumerator はマニフェスト外 dir を**空列挙**で返す（エラーだと列挙失敗の再試行ループ。削除の伝播は working set の didDeleteItems が権威）。
- **kind 衝突（同 path にリモート dir が実在）= `NSFileProviderError(.filenameCollision)`**: システムが片方をバウンス（リネーム）して createItem を再試行する（SDK 契約）。チェックはキャッシュ済みツリー基準 — RMW はファイル entry しか見ない（dir は合成物でシャード横断）ため、直後にリモートで dir が生える狭いレースは残る（既知の記録レースと同クラス・`ManifestTree` は directory-wins で破綻しない）。
- **ディレクトリ削除 = シャード単位バッチ RMW**（`ManifestUpdater.removeFileEntries`）: deleteItem は「数秒以内」がシステム契約のため、往復をファイル数ではなく**シャード数（≤256）で有界化**。dir の baseVersion（"dir"）は per-file ガードに使えないので、ベース = キャッシュ済みツリーの各ファイル sha（システムが直近に見ている世代と同源）。ガードは RMW 内（412 リトライごとにシャード内全対象を再評価）。**「拒否で即中断」**（2026-07-09 ユーザ確定）: 1 件でもベース不一致（リモート先行）が出たらそのシャードからは何も除去せず以降も中断し、`NSFileProviderError(.directoryNotEmpty)` を返す（SDK 契約: 再帰削除で消せない子がいる場合の正規コード。システムが dir を最新メタデータから再作成し、除去済み分の削除は次の enumerateChanges が配る）。非再帰削除で中身がある場合も同コード。除去成功分の delete marker は限定並列（4）で発行（失敗はログのみ = 単発 deleteFile と同じ規約）。追跡ファイルゼロ（仮想フォルダ / 消滅済み）は S3 非接触の冪等成功。回帰は `ManifestUpdaterTests` の removeFileEntries 系。
- **dir のメタデータのみ modifyItem は黙って受理**（マニフェストに保存先が無い・remainingFields に残すと永久再試行 = ファイル側と同じ理由）。**capabilities**: dir に `.allowsAddingSubItems` + `.allowsDeleting`（root は削除不可）を解放。改名/移動（`.allowsRenaming`/`.allowsReparenting`）は 5-4。
- **実機受け入れ**（2026-07-09・dev バケット）: 作成各種（通常/空/ターミナル/⌘D 複製 = dataless→materialize→createItem 複合）+ pull 反映 / 20MB マルチパートの SHA-256 往復一致 / 空フォルダ仮想受理 → ファイル投入で実体化収束（bounce ゼロ）/ 除外 4 種（`.env`・`.aws` subtree 単発・symlink・`*.pyc` = `ManifestIgnoreCache` 実動作）の非同期 + ローカル温存 + Finder バッジなし / ターミナル `rm -r`・Finder 削除の両方で `deleteItem(dir)` シャードバッチ → 伝播 / 受け入れ全期間 sync_log エラー 0。**受け入れ知見**: ① capabilities 変更は既存レプリカへ自動反映されない（root は working set 非掲載 + itemVersion 不変）→ ドメイン作り直し必須・5-4 でも再発する。② 作り直しの正規手順 = アプリ設定の Disable/Enable ボタン（`removeAllDomains()`）。システム設定のファイルプロバイダトグルは実行可否のみでレプリカを消さない。③ フォルダ改名（5-4 未実装）はローカル表示名だけ変わり item id = 同期パスは旧名のまま（配下の新規ファイルは旧名パスで上がる）。詳細は `docs/09` M5 節の 5-3 項。

#### rename / reparent（M5 Phase 5-4・2026-07-11）

- **ファイル move = sha 不変の path 移動**: ① `S3Client.copyObject` 新設（**ツリー現行 entry の versionId に固定**・SSE-S3 明示 = Copy は元の暗号化設定を引き継がない・metadataDirective COPY・5 GiB 事前拒否）。**最新版フォールバック禁止** — コピーは内容を検証できず、宣言版消失時に最新へ倒すと「宣言 sha と実体が乖離した entry」を作りマニフェスト真実が壊れる（404 は move 失敗 = 一時エラーで再試行）。② `ManifestUpdater.moveFileEntries` = **二相のシャード単位バッチ RMW**: Phase A で全移動先シャードに add（移動先に別内容が実在 = `.destinationOccupied` で中断・同一 sha は冪等素通し）→ **全 add 完了後に** Phase B の remove（5-3 の `removeFileEntries` へ委譲 = ベースガード・拒否で即中断）。どこで中断・クラッシュしても中間状態は常に「新旧両存（重複）」側（「データ損失 < 重複」）。③ 旧キーへ delete marker → キャッシュ無効化。新 entry は sha/size/mtime 維持（[mtime 不変条件] と整合）・identity はコピー結果。**内容変更 + 改名の複合 modifyItem** は copy の代わりに新内容を新 path へアップロード（filename と contents の同時同期 = SDK 推奨）。
- **id rebind = SDK の merge 機構で成立（PoC 最大の未知点・実機確定 2026-07-09）**: modifyItem の返却 item に**新 id**（`f:`/`d:` + 新 path）を載せると fileproviderd が受理し、ローカル実体を新 item に**束ね直す**（materialized のまま・fetch ゼロ・bounce ゼロを実機確認）。フォールバック不要。dir move では子孫 item が「旧 id 削除 + 新 id 出現」の diff で配信されるが、ローカル実体は物理 rename 済みのため materialized のまま収束した（計画時に想定した「dataless に戻る」より良い実挙動）。
- **rebind item の baseVersion は contentVersion がローカル版スタンプに差し替わる（実機確定 2026-07-11）**: rebind で生まれた item への**次の操作**（削除・再 move・内容編集）では、システムが渡す baseVersion.contentVersion が sha 形でない。対処は二層: ① **`FileProviderWritePolicy.baseSha(contentVersion:metadataVersion:)` の metadataVersion フォールバック** — Tide の file item は metadataVersion == contentVersion（同じ sha）で発行しており、システムは metadataVersion を保持していることを実機確認（rebind 後の削除・編集が本来のベースガードのまま正常化）。**file の metadataVersion = sha は load-bearing**（変えると rebind 後の全書込操作が壊れる・`FileProviderItem.itemVersion` のコメント参照）。② **ファイル move の remove ベースは itemVersion でなくツリー現行 entry の sha**（dir move と同方式）— move は「同一内容の add」と対の remove なのでツリーベースでもデータ損失は構造的に起きない（失敗 = 両存側・並行編集は RMW 再評価が弾く）。①の前に②を先行導入したのは、move が baseUnknown で**恒久リトライループ**になり後続操作（同 dir の削除等）まで詰まらせることを実機で踏んだため。
- **completion へ渡すエラーは SDK 規約ドメインへ包む**（`wrapForCompletion`）: NSCocoaErrorDomain / NSFileProviderErrorDomain 以外の Swift エラー（SyncError / MoveError 等）を素通しすると fileproviderd が CRIT fault を吐く（挙動は同じ一時エラー扱いだが規約違反・実機で観測）。規約外は NSXPCConnectionReplyInvalid + NSUnderlyingErrorKey で運ぶ（SDK ヘッダの指示どおり）。全コールバックの catch に適用。
- **`.sourceChanged`（リモート先行）は自動 rollback せず一時エラー返却** — copy は毎試行ツリー現行 entry から引き直すため、リモート変化が届いて baseVersion が追いつけば再試行の move が「進んだ後の内容」で自己回復する（stale 内容を運ばない）。`.destinationOccupied` は `FilenameCollision` でシステムに名前バウンスさせる。
- **除外名への改名 = 後始末予約方式（2026-07-09 ユーザ確定 + 実機で設計修正）**: 新 path が除外対象（検証不能名 / 機密網 / ユーザ `.syncignore`）なら `ExcludedFromSync` を返す。**マニフェストはその場では触らない** — SDK は除外時に「内容をダウンロードしてから deleteItem を発行」する契約で、先に entry を消すと dataless の item が materialize できない殻になる（実機で確定・初期実装の先回り除去は撤回）。ただしシステムの後始末 deleteItem は **baseVersion が sha 形でない**（ローカル保留変更の版スタンプとみられる・実機観測）ため、除外した path を **`PersistedPathSet`（後始末予約）** に登録し、deleteItem 側で「予約済み path かつ **base が両 version から復元不能（nil）のときだけ**、ツリー現行 sha をベースに RMW ガード付きで受理」する（PR #60 レビュー #1: metadataVersion フォールバックで sha が取れる deleteItem は本来のベースガードが常に優先 = 予約が残留しても正当な削除のガードを弱めない）。dir の除外は subtree ごと `ExcludedFromSync`（後始末の dir deleteItem は元々ツリー sha ベースなので予約不要）。結果 = FSEvents の「旧 path 削除伝播 + 新 path 非同期・ローカル温存」と対称。
- **仮想フォルダの温存は `PersistedPathSet`（レジストリ）に限定（5-3 の設計修正）**: 5-3 の「マニフェスト外の dir id へ無条件に合成 dir を返す」は、dir move の reconcile 中の照会で**消えたはずの旧 dir を空フォルダとして復活させる**ことが実機で確定。`item(for:)` / enumerator が合成 dir を返すのは「createItem で仮想受理した = レジストリ登録済み」のパスだけに変更（レジストリ外は noSuchItem）。レジストリは App Group Caches の JSON（世代ログと同格・bucket キー・読込時 `validateRelativePath` 再適用・壊れは全体破棄 = 温存保証を失うだけ・上限 1000）。createItem(dir) で追加 / 配下ファイルの実体化で祖先を除去 / dir 削除・除外で subtree 除去 / rename で subtree 追従。
- **capabilities**: file/dir に `.allowsRenaming` + `.allowsReparenting` を解放（root は不可）。capabilities 変更のため既存レプリカはドメイン作り直しが必要（5-3 知見①のとおり・受け入れで実施）。
- **実機受け入れ**（2026-07-09〜11・dev バケット）: ファイル rename（ターミナル/Finder）+ id rebind + materialized 温存 / reparent（ターミナル mv / Finder ドラッグ）/ dir rename（copy 2 + 二相 RMW・旧 dir 非復活）/ 除外名 rename（予約 → 後始末 deleteItem 受理 → 旧 entry 除去・ローカル温存・非復元）/ 仮想フォルダ rename（レジストリ追従）/ すべてアプリ pull への伝播まで確認・sync_log エラー 0。

#### 並走 UI の本実装化（M5・2026-07-12）

- Phase 5 完了（書込系コールバック全対応）を受けて、PoC 世代の UI/命名を正式化した。**既定化判断は #40 soak 後**のまま（FSEvents モードとの opt-in 並走は不変）。
- **`FileProviderPoC` → `FileProviderController` リネーム**（`Tide/Core/`・ロジック不変）。設定画面の FP セクションから experimental / PoC 表記を除去し、説明文を実態（読み取り専用プレビュー → **双方向同期 = FP 側の追加・編集・削除は S3 へ直接同期される「第 3 のデバイス」**・無効化はレプリカ削除のみで S3 側データは残る）に是正。
- **ドメイン identifier `"poc"` → `"main"`**（ユーザ確定 2026-07-12・作り直し了承済み）。identifier スキーマ変更は必ずドメイン作り直しで行う（Phase 5-1 実機確定: 無再作成移行は旧 id item が「名前 2」リネームで恒久残存）ため、**`migrateStaleDomainsIfNeeded()`** を新設し `AppEnvironment.bootstrap()` から fire-and-forget で実行 — 現行と異なる identifier のドメインを検出したら作り直し、「有効化済み」というユーザ意図を引き継ぐ（無し/現行のみなら no-op・失敗は非致命 = 設定画面の Disable/Enable で回復可能）。
- **移行の堅牢化（PR #61 レビュー #1/#2）**: ① stale は **per-domain `remove(_:)`** で外す（`removeAllDomains` は使わない）— stale と現行 `"main"` が共存するケースで健全な現行レプリカ（materialize 済みコピー・S3 未到達の保留書込）を巻き込まない。② remove 前に **pending フラグ**（group defaults `fileProviderMigrationPendingAdd`）を立て、成功時に消す — 「remove 成功 → add 失敗」の中断では stale 検出が no-op になり移行が再走しないため、次回起動はフラグから add だけ再開する（= 有効化意図が静かに失われる窓を閉鎖）。明示的な `disable()` はフラグも消す（ユーザの無効化意思が移行再開に勝る）。
- **自動移行は旧ドメインのレプリカごと破棄する** = 旧ドメイン内の S3 未到達の保留書込（オフライン編集・拡張リトライ中の書込等）は失われる（PR #61 レビュー #3・記録）。手動 Disable/Enable と同じ挙動だがアップデート後の初回起動に無警告で起きる点が異なる。identifier 変更は今回の一度きり・ユーザ了承済み。今後 identifier / ドメイン属性を変える際はこの破棄を前提にアナウンスすること。
- ドメインフォルダ名 `Tide-Tide` は displayName 由来で identifier 非依存（変わらない）。拡張側はドメインを引数で受けるため identifier 非参照 = 無傷。
- **実機知見（2026-07-13 受け入れ）: 自動移行直後は Finder サイドバーの「場所」項目が消えたままになることがある** — remove → add が 20ms で連続するため Finder が再登録イベントを取りこぼすとみられる。ドメイン・列挙・レプリカは正常（fileproviderd は `Removing domain …/poc` → `Adding domain (main)` → starting domain を正常記録）で、**`killall Finder` で復帰**。一度きりの移行の cosmetic な癖として記録（設定の Disable → Enable のような人間の操作間隔では発生しない）。

#### FP 実体化連動バッジ（Issue #65・2026-07-14）

- **要件**: 「実体化されているときだけ Finder にチェックバッジ」（静的バッジは dataless にも付き誤読される — 2026-07-12 試作 → 撤去の再挑戦）。対象は**ファイル + ディレクトリ両方**（ユーザ確定）。dir のチェック基準 = **配下に 1 ファイル以上あり、かつ配下全ファイルが実体化済み**（空フォルダ・仮想フォルダはチェックなし）。バッジは S3 非接触の純ローカル機能。
- **実体化状態の追跡（live / reported の 2 面）**: 真実 = fileproviderd（`NSFileProviderManager.enumeratorForMaterializedItems()` で全量取得・`materializedItemsDidChange` が変化通知）。**live**（最後に観測した集合）は `MaterializedObserver`（actor・メモリのみ）、**reported**（Finder へ最後に報告した集合）は `PersistedPathSet` の 3 本目 `fileprovider-materialized.json`（**上限は init 注入化して 10,000**・既存 2 用途は 1000 不変・溢れ = バッジ欠落のみの安全側で `MaterializedBadge.cappedReport` と `replace(with:)` が同一の昇順 prefix 規則 = 再送チャーンなし）。evict（「ダウンロードを削除」）は拡張の他コールバックを経由しないため、didChange → 観測 → reported と食い違えば自己 signal、が唯一の消灯検知経路。
- **metadataVersion の複合符号化**: file = `<sha256>`（+ 実体化時 `|m`）/ dir = `dir-<mtime>`（+ `|m`）。**contentVersion には絶対に載せない**（内容変化の意味になり再取得を誘発）。file の sha プレフィックスは rebind 対応の load-bearing のまま — `FileProviderWritePolicy.baseSha` が既知サフィックスだけ剥がして復元する（未知サフィックスは従来どおり不正・往復は `FileProviderWritePolicyTests` で固定）。非実体化形は旧形式と同一 = 後方互換。
- **配信 = enumerateChanges への eventual オーバーレイ（anchor 意味論の外・docs/09 の設計判断どおり）**: **報告点（reported の前進 = `replace(with:)`）は working set の enumerateChanges だけ**（コンテナ enumerator が消費すると working set 経由の配信が空振りしてバッジが固着する）。live と reported の差分（`MaterializedBadge.changedPaths` = 点灯/消灯ファイル + チェック反転 dir）を didUpdate に合流させ、マニフェスト無変化でも badge-only 更新を同一 anchor のまま配る。**dir 反転の before 側は origin（= Finder が最後に見た世代）のツリー基準**（PR #66 レビュー指摘 1）: 両側を新ツリーで計算すると「実体化集合は不変・ツリーだけが変わった」反転（リモート削除で配下全実体化 / 古い mtime のリモート追加で dataless 混入 — どちらも dir の合成 mtime が動かずマニフェスト diff に dir が載らない）が対称差に現れずチェックが固着する。reported の replace は badge 配信の有無と独立に前進（stale パス残りで live != reported が恒常成立 → 空振り signal ループ化するのを防ぐ・同 nit 1）。didUpdate の全 item（マニフェスト diff 分も）のフラグは newReport 基準に統一。move は `renameSubtree` で reported を構造追従（チャーン防止）・削除は `removeSubtree`。fetchContents / createItem / modifyItem の返却 item は実体化済みフラグ付き（内容がローカルにある）だが reported はその場で触らない（先に足すと祖先 dir の反転差分が消える）。
- **表示**: `FileProviderItem` が `NSFileProviderItemDecorating` 準拠・実体化時のみ `org.izukawa.Tide.materialized`（`project.yml` の `NSFileProviderDecorations` 宣言・BadgeImageType = システム UTI `com.apple.icon-decoration.badge.checkmark`）。ツリー由来の item 構築は `BadgeFlags`（tree + reported → dir 集計 1 回）経由 — プレーン構築で返すと報告済みバッジがメタデータ regress で消えたまま固着するため。判定本体は TideCore の `MaterializedBadge`（純粋・`MaterializedBadgeTests`）。
- **既知の注意**: ① metadataVersion 形式 + Decorations 追加のため**既存レプリカはドメイン作り直し必須**（capabilities と同じ）。② **個々のファイルの materialize/evict とも OS の実体化セットに現れることを実機確認済み（2026-07-15 受け入れ）** — 設計前提成立（観測数の notice ログで判定）。③ バッジの Label（hover/VoiceOver）は Info.plist 値のため未ローカライズ = en「Downloaded」固定。
- **実機受け入れ（2026-07-15・全項目パス）で確定した挙動**: dir move は配下の実体化が失われる（dataless 化 = Phase 5-4 パスベース id の帰結）ためバッジも消灯する — 実状態の正しい反映で誤点灯・チャーンなし（単一ファイル rename は id rebind で実体化ごと維持 = バッジも維持）。ドメイン作り直し直後の stale reported（`fileprovider-materialized.json` 残置分）は新レプリカ初回 insert に deco 付きで載る**約 0.3 秒の過渡**の後、badge-only update が deco を除去して自己修復~~（固着なし）~~（**後日訂正**: 自己修復は消灯方向のみ — 点灯方向は stale reported が「報告済み = 差分なし」を装い**永久不点灯で固着**することが判明 = Issue #104。恒久対処 = ドメイン epoch リセット・下記「FP レジストリのドメイン epoch リセット」節）。Finder プレビューペイン表示中の evict は EBUSY で失敗（OS 挙動）。知見一覧は `docs/09` M5 バッジ節。

#### FP-only 稼働モード B-0 = モード基盤 + RemoteChangeSignaler（M5 Track B・2026-07-22）

> **v0.3.0 #96（2026-08-08）で更新**: bootstrap のモード分岐と「既定 folderSync」は撤廃 —
> boot は無条件 fpOnly・`ConfigStore.syncMode` は外部ツール契約キーへ転生（下記 #96 節）。
> 本節のモード分岐まわりの記述は当時の記録。`RemoteChangeSignaler` の仕様は現行のまま有効。

FP 一本化（切替前 soak ゲート撤廃 = `docs/09` #40 節・2026-07-22 ユーザ確定）の Track B 第 1 段。

- **`ConfigStore.syncMode`**（`folderSync` / `fpOnly`・既定 `folderSync`）: 未知の保存値も
  `folderSync` へフォールバック（常に実績のある安全側で起動）。**適用は次回起動から**
  （稼働中の動的切替はしない = 転送中断・キュー残行ありの停止遷移を構造的に回避。ユーザ確定
  2026-07-22）。`migratableKeys` 掲載 = `reset()`（再セットアップ）でクリアされ folderSync へ戻る。
  `SettingsTransfer` にはフィールドが無く構造的に含まれない（マシン固有の運用選択）。
- **bootstrap 分岐**（`AppEnvironment.launchEngineFromCurrentConfig` 冒頭）: `fpOnly` なら
  `launchFPOnlySignalerFromCurrentConfig` へ — SyncEngine（FSEvents 監視・pull・アップロード
  キュー）を起動せず `RemoteChangeSignaler` だけを立ち上げる。**DB / syncRoot / bookmark には
  一切触れない**（DB は開かない = `pruneOldLogs` 等の書込も走らない。凍結温存 = `folderSync`
  復帰時に SyncEngine の pull が shard_state の etag 差分で FP-only 期間中の変化を増分検出できる
  = モード可逆性の要）。必須設定は bucket / region / 資格情報のみ（syncRootPath は検証しない）。
  TLS 強制バケットポリシーの自己修復は両モード共通で適用。bootstrap の再入ガードは
  `engine != nil || signaler != nil`（モードごとにどちらか一方だけが立つ）。`factoryReset` は
  signaler も停止・破棄する。
- **`RemoteChangeSignaler`**（`Tide/Core/RemoteChangeSignaler.swift`・@MainActor）:
  `.tide/index.json` の **HEAD ETag** をポーリング間隔（`pollingIntervalSeconds` 流用・既定 180 秒）
  + wake / ネットワーク復帰の即時契機（SyncEngine の pull トリガと同型の配線・`LastSatisfiedHolder`
  共用）で比較し、変化時のみ `FileProviderController.signalRemoteChanges()`（coalesce は向こう側）。
  増分取り込み本体は拡張の `enumerateChanges` が担うため、アプリの仕事は通知だけ（HEAD 1 発 ≒
  数十バイト/周期）。**不変条件**: ① DB / shard_state 非接触（構造的に依存を持たない）。
  ② index 不在（未セットアップ / 空バケット）は無反応・ベースラインも作らない（初出現を変化として
  拾う）。③ HEAD 失敗は保持 ETag を進めない（一過性エラーで変化を取りこぼさない・次契機で回収）。
  ④ 初回チェックはベースライン確立 + 無条件 1 回 signal（アプリ停止中に溜まった変化の取り込み保険。
  変化が無ければ拡張側の世代キャッシュで no-op）。依存注入（HEAD / signal クロージャ）で
  `RemoteChangeSignalerTests` が直接駆動。多重チェックは `isChecking` で coalesce（@MainActor の
  check-and-set・進行中に届いた契機はドロップ = 定期契機が必ず後続する）。
- **レビュー反映（PR #75）**: `pollingIntervalSeconds` getter に下限 30 のクランプ（負値/極小値の
  保存で pull / HEAD が密ループ化する既存の穴を両モードまとめて閉鎖・任意 2）・`RemoteChangeSignaler`
  の `start()` 再入安全（先に stop）+ `deinit` でのタスク / NWPathMonitor 破棄（任意 3）・観測ログの
  forensics 強化（契機ラベルは `.public`・ベースライン signal も info 1 行 = 切替後ライブ soak の
  主観測点。Info ログは 10〜15 分で消える運用実態のため・任意 4）・index キーを
  `TideS3Client.indexKey` へ定数化（リテラル drift = HEAD 404 → nil → 無反応で**無エラーの検出沈黙**
  になるのを防ぐ・任意 5）。**記録（レビュー 6）**: `LegacyStateMigrator.migrateIfNeeded()` はモード
  分岐より前に走るため、旧ロケーションからの一度きりファイル移動だけは fpOnly でも起こりうる
  （内容を変えず場所を移すだけ・既移行環境では no-op = shard_state 凍結の不変条件は破らない）。
- **残（Track B の続き）**: ~~B-1 = 設定画面のモード切替 UI + fpOnly 時のメニューバー表示縮退~~
  （✅ 2026-07-22 実装・下記 B-1 節）、~~B-2 = S3 内復元（`S3RestoreService`）~~（✅ 2026-07-23
  実装・下記 B-2 節）、~~B-3 = `soak-check --fp-only`~~（✅ 2026-07-24 実装・下記 B-3 節）、
  ~~B-4 = 切替ランブック~~（✅ 2026-07-25 実施・下記 B-4 節。Keep Downloaded 運用 = 重要
  ファイル投入後にルートを「ダウンロードを保持」はゲート通過後に適用・非ピン実体化分の
  自動 evict は未検証 = 切替後ライブ soak の観察項目）。**Track B はこれで全完了**。

#### FP-only 稼働モード B-1 = モード切替 UI + 表示縮退（M5 Track B・2026-07-22）

> **v0.3.0 #96（2026-08-08）で更新**: 「Sync mode」セクションと folderSync 側フォールバック
> （「Open Sync Folder」）は撤去（下記 #96 節）。fpOnly 側の表示縮退（fpOnlyHeader / 状態カード /
> Sync Activity・Version History の扱い）は現行のまま有効。

- **設定画面「Sync mode」セクション**: radioGroup の Picker（Folder sync / File Provider only）。
  他設定と同じ @State write-through（`ConfigStore.syncMode` へ即保存）だが**適用は次回起動から**
  （B-0 の確定方式）— いま稼働しているモード（`runningSyncMode` = `env.signaler != nil ? fpOnly :
  engine != nil ? folderSync : nil`）と保存値が食い違うときだけ「Quit and reopen Tide to apply」を
  表示する。fpOnly 選択時に FP ドメインが無効なら橙警告（**ハードブロックはしない**: 有効化は同じ
  設定画面の Enable ボタンで即できるし、無効のまま fpOnly で起動しても signaler の isEnabled ガードで
  no-op + ポップオーバー側の赤警告で気づける = 単純さ優先）。
- **ポップオーバーの fpOnly 分岐**: `engine == nil` × `signaler != nil` で `fpOnlyHeader` を表示
  （**「Starting…」恒久表示の解消 = PR #75 レビュー低 1**）。ヘッダ（File Provider Sync）+ 状態カード
  （最終リモート確認 / 最終変化 signal / 失敗中の橙表示）+ FP ドメイン無効時の赤警告（何も同期されて
  いない旨）。状態は `RemoteChangeSignaler` を **@Observable 化**した読み出し専用プロパティ
  （`lastCheckedAt` / `lastSignaledAt` / `lastCheckFailed`・判定ロジックへの影響ゼロ・遷移は
  `RemoteChangeSignalerTests.testObservableStateTransitions` で固定）。
- **secondary アクションの縮退**: fpOnly では「Open Sync Folder」を「Open Tide in Finder」
  （`FileProviderController.userVisibleURL()` = `getUserVisibleURL(.rootContainer)` 新設）へ差し替え
  （凍結温存中の同期フォルダを開かせると「同期されないフォルダ」を同期先と誤認するため）。
  Sync Activity は既存の `engine != nil` ゲートで自然に非表示（fpOnly は DB を開かないため
  sync_log が読めない = 表示できないのが正しい）。~~Version History も同ゲートで非表示~~
  （B-1 当時の判断 → **B-2 で復権**: 列挙は元々 S3 直参照・パス一覧はマニフェスト読みで代替・
  復元は S3 内復元へ分岐。下記 B-2 節）。
- **文言**: 新規 12 キーを `Localizable.xcstrings` へ追加（`extractionState: manual`・ja 翻訳済み。
  「Last remote check: %@」は engine カードと共用の既存キー）。

#### FP-only 稼働モード B-2 = S3 内復元（M5 Track B・2026-07-23）

fpOnly は DB / syncRoot に触れないため、既存のローカル書き戻し復元（`SyncEngine.restore` →
`RestoreService`）が使えない。代替は **`S3RestoreService`（`TideCore/S3/`）= 選んだ過去版を
S3 の新しい現行版として書き直す**（方式はユーザ確定 2026-07-22: tmp DL → 現行版 PUT →
`ManifestUpdater` 合流）。FP レプリカへの反映は書込確定点の signal → `enumerateChanges` に乗る。

- **手順**: `validateRelativePath` → `headObject(versionId:)` で真実サイズ（履歴版に sha/size は
  無い = M7 と同じ担保）→ **アップロード上限を DL 前に適用**（復元は再アップロードを伴うため
  `PartPlan.isWithinUploadLimit`。超過は `fileTooLarge`）→ 3-way ベース = 復元開始時点の現行
  entry sha（`updater.store.getShard`。無ければ base nil = 削除済み/未追跡の新規作成側）→
  Caches tmp へストリーム DL（走りながら sha256・超過即破棄・実サイズ突合）→ **現行と同一 sha
  なら PUT もマニフェスト書込もしない no-op**（`.alreadyCurrent`・版チャーン防止）→ 本体 PUT
  （`NoFollowFileReader` 単一 FD・16 MiB 超は `MultipartUploader`・SSE-S3 は実装側で常時付与）→
  `updateFileEntry(base:)`。競合は RMW 内 `decideUpload` が `uploadConflict` で安全中断
  （ローカル書込ゼロなので退避不要・PUT 済みの版は「マニフェスト外の不可視 live 版」として
  残る = アプリのアップロード競合と同じ特性・版履歴で回収可）。
- **entry の mtime = 復元時刻（now）**（ユーザ確定 2026-07-23）: folderSync 復元（ローカル書き
  戻し → 再アップロードが stat 実値 = 復元時刻を記録）と観測挙動が対称。
- **配線**: `AppEnvironment.makeS3RestoreService()`（fpOnly 稼働中 = `engine == nil` ×
  `signaler != nil` のときだけ非 nil）。`ManifestUpdater` の `onManifestDidWrite` に
  `FileProviderController.signalRemoteChanges()` を配線（アプリ Uploader の `onManifestWrite` と
  同型）。帯域制御は config の up/down 値から都度 `RateLimiter` を構築。tmp は
  `TideTmpDirectory.cacheTmp()`（新設 = Caches 側固定。復元 tmp は PUT 後に消すだけで
  ローカルへの atomic move が無いため同一ボリューム要件も無い）。
- **UI**: ポップオーバーの「Version History…」を fpOnly でも表示（`engine != nil || signaler !=
  nil`。Sync Activity は DB 由来のため engine のみ維持）。`VersionHistoryModel` は engine 不在 ×
  `makeS3RestoreService()` 非 nil で S3 内復元へ分岐（Versions / Deleted 両タブ共用の
  `restoreInS3`。成功時は削除一覧からも除去 = 原 key に現行版が乗る）。**Versions タブの
  パス一覧は fpOnly ではマニフェスト読み**（ユーザ確定 2026-07-23: `ManifestSnapshotLoader` =
  拡張と同じ DB 非接触読み取り専用ローダ・FP レプリカが見ている真実と同一ソース。ウィンドウを
  開いたときだけの読みでコスト許容）。版列挙・削除済み一覧は元々 S3 直参照（`listObjectVersions` +
  `DeletedFilesCache`）のため fpOnly でそのまま動く。
- **回帰**: `S3RestoreServiceTests`（新現行版書込 + signal 発火 / 削除済み復元 = base nil /
  no-op 短絡 / 並行更新の `uploadConflict` 中断・無音上書きなし / サイズ不一致・超過・上限の
  各ガード / 不正パス入口拒否 / マルチパート経路のパート結合一致 / tmp 後始末）。
  セキュリティ面の対応記録は `security/README.md` M4 復元レビュー節の追記（2026-07-23）。
- **レビュー反映（PR #77）**: ① 中 1 = 復元直後の一覧再読込（`loadVersions`）が入口リセットで
  結果表示（成功 note / `uploadConflict` 等の失敗）を描画前に消す → `reloadVersionsPreservingOutcome`
  （退避 → 再読込 → 非 nil のみ再適用・復元エラーを再読込エラーより優先）。folderSync 側の
  成功 note が M4 以来消えていた既存事象も同修正で解消。② 低 1 = 現在ディレクトリ化している
  パスへの S3 内復元が file/dir 同名衝突をマニフェストへ注入できる（folderSync はローカル書込が
  構造的に防ぐ・S3 内復元にはローカル面が無い）→ **UI 層の事前拒否**（ユーザ確定 2026-07-23）=
  `VersionHistoryModel.hasKindConflict`（path が現在 dir = 配下に同期済みファイルあり / 祖先が
  現在 file をマニフェスト全景で判定・`VersionHistoryKindConflictTests`）。**ベストエフォート**:
  一覧未ロード / stale は素通しだが、発生してもデータ損失は無く FP ツリーの directory-wins と
  folderSync pull の #52 系処理で回収できる。ガードの材料になる `loadSyncedPaths` はウィンドウ
  オープン時ロードへ移動（Deleted タブ直行でも武装。再レビュー任意 1 = 直列ロードが fpOnly の
  削除一覧キャッシュ即表示 #29 (b) を遅らせるため `.task` 2 本の並行ロードへ）。記録のみ 2 件 =
  クラッシュ時の `s3restore-*.part` 残骸は次回同一復元まで残る（Caches 配下 = システム purge
  対象・現状維持）/ `errorMessage` の生エラー文字列は既存パス踏襲。
- **実機受け入れ（2026-07-24・dev バケット・全項目パス）**: fpOnly 切替往復（適用は次回起動
  から / `Launched in FP-only mode` / ベースライン signal）・fpOnly ポップオーバーと縮退
  メニュー・S3 内復元の全経路（通常 = note 残留 + レプリカ 0.5 秒反映 / no-op = 版数不変 /
  削除済み = marker 越し復活 / kind 衝突 = UI 事前拒否で PUT ゼロ / 20MB マルチパート = sha
  完全一致）・`RemoteChangeSignaler` の 180 秒 poll が index 変化を 4 回検知 signal・folderSync
  復帰の増分 pull（fpOnly 期間の変化 3 件だけを DL = shard_state 凍結温存の実証）・folderSync
  復元 note 残留（中 1 補足の回帰）・`make soak-check` 整合 OK。
- **受け入れで発見・修正したバグ 2 件（B-1 起源・fpOnly 初実稼働で顕在化）**: ①
  `getUserVisibleURL` の返す URL は **security-scoped** — scope を開始せず `NSWorkspace.open`
  へ渡すと sandbox 下で LS が「"Tide-Tide" を開くアクセス権がありません」と拒否する →
  `startAccessingSecurityScopedResource` で挟んで修正。② メニューバーアイコンが fpOnly で
  恒久「？＋波」（`MenuBarLabel` が engine nil を `.notConfigured` に落とす）→
  `MenuBarPresentation.fpOnlyHeadline`（正常 = 通常の波 / 直近リモート確認失敗中 = 荒れた海・
  `MenuBarPresentationTests` で固定）へ。
- **受け入れ中のインシデント記録: `soak-check` が実 DRIFT（stale index 宣言）を初検出**:
  シャード 79 の index 宣言 etag/count が実体より古いまま残存（発生 = 2026-07-22 02:39 JST の
  churn 期・同一秒の 2 連続シャード書込の 2 本目の updateIndex 未反映 = PR #56 記録の既知
  残余クラス。自己治癒条件「次の同シャード書込」が対象シャード無変化のため 2 日間不発）。
  実害 = 宣言 etag をキャッシュ済みの読者に exr 1 件が不可視（S3 実体・本機 DB は健全 =
  データ損失なし）。**治癒手順** = 対象シャードへ落ちるパス名の小ファイルを同期フォルダに
  作成 → アップロードの `commitShardWrite` が宣言を実 etag へ更新 → ファイル削除で原状復帰
  （シャード ID は `sha1(path)[0]` で総当たり選定）。B-2 とは無関係の既存事象で、切替後
  ライブ soak がこのクラスを検出できることの実地実証になった（`docs/09` #40 節）。
- **PR #78 レビューの記録 2 件（✅ いずれも Issue #82 実装で解消 2026-07-25）**: (a) fpOnly × FP 拡張無効（システム設定で OFF =
  何も同期されない）でもメニューバーアイコンは「通常の波」のまま — signaler は index HEAD の
  到達性しか見ない。ポップオーバーの赤警告で気づける。将来やるなら signaler 側で低頻度に
  `isEnabled()` を併観測して合成（2026-07-25 **Issue #82 へ格上げ** = fpOnly 常用化で
  「拡張 OFF = 全同期停止が soak-check にも映らない」盲点が実利用リスクになったため）。(b) `fpOnlyHeadline` の `.error(summary: "")` は空文字
  センチネル — 将来 fpOnly の presentation を `headlineText` 系へ流すと「Error: 」表示になる
  罠（現状はアイコン用途に閉じている旨のコメント + テストでガード済み。必要になったら専用
  case（例: `.remoteCheckFailed`）化が構造的）。
  **解消の実装（Issue #82・2026-07-25）**: `RemoteChangeSignaler` が HEAD と同契機
  （startup / poll / wake / networkUp・ユーザ確定）で `FileProviderController.isEnabled()`
  （ローカル XPC 1 発）を併観測し、観測状態 `fpDomainDisabled` を公開。HEAD より先に観測する
  （拡張 OFF の検出は S3 到達性と独立 = オフラインでも気づける）。ログはエッジ検出時のみ
  （無効化 = `.error` 1 回・恒常ノイズにしない #81 と同方針 / 復帰 = `.notice`）。**復帰エッジは
  ETag 不変でも必ず 1 回 signal** — 無効期間中も HEAD は ETag を進めており（その間の signal は
  `FileProviderController` 側 isEnabled ガードで no-op）、次の変化まで取り込み契機が来ない
  「見逃し窓」を catch-up で閉じる。表示は `MenuBarPresentation` の専用 case 化
  （`.fpDomainDisabled` = 赤・確認失敗より常に優先 / `.fpRemoteCheckFailed` = 橙。
  ともにアイコンは荒れた海）で、(b) の空文字センチネルも同時に廃止。回帰は
  `RemoteChangeSignalerTests`（エッジ検出 / catch-up / HEAD 失敗と独立）+
  `MenuBarPresentationTests` で固定。ポップオーバー開時の `isEnabled()` 直接取得（B-1）は
  より新鮮なため従来どおり並存。**PR #88 レビューの記録 1 件（対応不要）**:
  `isEnabled()` は判定不能（`domains()` の XPC 一過性失敗 = `try?` → 空配列）を「無効」に
  畳むため、偽の無効エッジ（`.error` 1 回 + 赤アイコン最大 1 周期 + 偽復帰の `.notice` +
  余分な catch-up 1 発・いずれも無害/自己回復）が出得る。既存の `performSignal` ガード・
  B-1 ポップオーバー警告と同じ畳み方で一貫しており現状許容。将来強化案 = 三値化
  （有効 / 無効 / 判定不能）して判定不能は前回状態維持（エッジ非発火）。

#### FP-only 稼働モード B-3 = soak-check --fp-only（M5 Track B・2026-07-24）

切替後ライブ soak（`docs/09` #40 節 = persistent DRIFT ゼロの事後ゲート）の観測係。
fpOnly ではアプリが DB / syncRoot に触れない（凍結温存）ため、通常スコープの
`consistency_check.py` は「凍結 DB vs 生きたマニフェスト」の比較で偽 DRIFT を量産する —
突合面を S3 側へ縮退した `--fp-only` を追加した（`make soak-check-fp` / `soak-watch-fp`）。
実装は `tools/soak/consistency_check.py`（アプリと独立・読み取り専用は維持）。

- **残す**: index ↔ shards 構造整合（B-2 受け入れ中にシャード 79 の実 DRIFT を検出した
  実績面）/ マニフェスト ↔ S3 実体（孤児含む）/ Caches tmp 残骸 / リソース観測（本体 +
  FP 拡張）。**落とす**: DB 系すべてと同期フォルダ走査（比較相手が生きていない）。
  設定解決も sync-root / DB を必須にしない。
- **DB 凍結見張り**（`DBFreezeWatch`）: `db.sqlite` / `-wal` の mtime を stat のみで観測し、
  プロセス内の前回観測から前進したら WARN = 「fpOnly なのに DB が書かれた」（bootstrap
  分岐のバグ = モード可逆性の要が壊れている疑い）を無エラーのまま見逃さない。DB は
  開かない。実効性は `--watch` 常駐時（単発は実行中の窓のみ）。**保存モードが fpOnly の
  ときだけ武装**（folderSync 中の `--fp-only` 予行で正当な DB 書込を誤報しない）。
- **突合ガード**: 保存 `tide.syncMode` = fpOnly なのに `--fp-only` 無しは exit 2 で案内
  （偽 DRIFT の cron 誤発報を構造的に防ぐ・exit 1 と区別）。逆は予行として WARN + 続行。
  `--deep` との併用は exit 2（fpOnly はローカル実体を突合しない）。
- **ついでの穴埋め（両モード共通）**: tmp 残骸検出へ `s3restore-*.part`（B-2 の S3 内復元の
  クラッシュ残骸クラス・PR #77 記録）を追加。watch JSONL に `fp_only` / `db_mtime` を追加。
- スモーク確認（2026-07-24・実 S3 327 件）: `--fp-only` = fp-only 整合 OK + 予行 WARN /
  通常スコープ = 整合 OK（回帰なし）/ `--deep` 併用 = exit 2。
- **レビュー反映（PR #79）**: ① 中 1 = watch 常駐がモード切替（ランブック実施）を跨ぐと
  起動時スコープのまま偽 DRIFT / 偽 WARN を積み続ける → **実モードを毎周回再読**し、起動時と
  食い違ったら `mode:switched` WARN（watch 再起動の案内）。凍結見張りは切替検出中 `resync()`
  で基準だけ追従（folderSync 期間の正当な書込を誤報せず・fpOnly 復帰後の初回比較でも
  偽 WARN しない）。**B-4 ランブックにも「切替の前後で soak-watch を停止 / 再起動する」を
  明記する**（WARN は保険・正規手順は再起動）。② 低 1 = DB **不在 → 新規出現**も mtime 前進
  として WARN（fpOnly 中に DB が生える = bootstrap 分岐バグの一形態・見逃していた）。
  ③ nit = `--fp-only` × `--sync-root` 明示指定は stderr で「使わない」ことを通知。

#### FP-only 稼働モード B-4 = 切替ランブック実施（M5 Track B・2026-07-25 全項目パス）

切替ランブック（tmp 使い捨て・実施後削除）を実施し、**FP-only 稼働モードへ切替済み・ライブ
soak 開始**。以後この Mac の同期は FP レプリカ（`~/Library/CloudStorage/Tide`・実体
`Tide-Tide`）が唯一の作業面で、旧同期フォルダは凍結温存。

- **事前整備**: soak-watch 非稼働確認・切替前ベースライン `make soak-check` 整合 OK
  （manifest/db/s3 = 327・local 329・INFO は `.DS_Store` 2 件のみ）。
- **B-1 持ち越し 2 項目を機会実施（これで B-1 も受け入れ完了）**: ① ja / en 文言
  （`make run-ja` / `run-en`・Sync mode セクション・再起動案内の表示 / 戻すと消滅）
  ② FP ドメイン無効時の橙警告（Disable → fpOnly 選択 → 橙警告 → Folder sync へ戻して
  Enable → レプリカ再構築。Disable 前にベースライン整合 OK = 保留書込破棄の安全確認）。
- **切替**: Sync mode = File Provider only → 再起動 → ログで `Launched in FP-only mode` +
  `RemoteChangeSignaler started (interval: 180s)` + `baseline established; signaled FP domain`
  を確認。UI = メニューバー通常の波（`MenuBarWave` = 月＋ゆるい波）・fpOnly ポップオーバー・
  「Open Tide in Finder」。
- **書込スモーク往復**: FP レプリカへターミナルからファイル作成 → 約 40 秒で manifest / s3
  328 件・`soak-check-fp` = fp-only 整合 OK・**warn 0**（予行 WARN 消滅 = 保存モード一致の
  実証・凍結見張り武装下で DB 書込なし）→ 削除 → 327 件へ復帰・整合 OK。
- **ライブ soak 開始（2026-07-25・#40 事後ゲート）**: `make soak-watch-fp` を専用ターミナルで
  常駐（300 秒間隔・JSONL = `~/Library/Logs/TideSoak/soak.jsonl`）。運用ルール = ファイル作業は
  FP レプリカ側のみ / モード変更時は watch 停止 → 切替 → 再起動 / マシン再起動後は watch 手動
  再開（**watch 駆動は同日 launchd 常駐へ更新 = 下記 #84 項。手動再開は不要になった**）/
  persistent DRIFT は #40 へ記録・即調査（Info ログ揮発のため一次証跡は即採取）。
  観察項目 = 非ピン実体化ファイルのディスク圧迫時自動 evict（Keep Downloaded 運用の要否根拠）。
  ゲート通過後に重要ファイル投入 + ルート「ダウンロードを保持」（Keep Downloaded 運用）。
  「Tide を唯一のバックアップにしない」は継続。
- **soak-watch の launchd 常駐化（2026-07-25・Issue #84 = 標準運用へ格上げ・ユーザ確定）**:
  マシン再起動後の「手動再開忘れ = 観測空白」（DB 凍結見張りも停止）を構造的に防ぐため、
  `make soak-agent-install` で LaunchAgent（`org.izukawa.tide.soak-watch`・
  `consistency_check.py --fp-only --watch 300`・KeepAlive + RunAtLoad・異常終了 60 秒スロットル）
  常駐へ移行 = watch 駆動の標準。**運用ルールの読み替え**: マシン再起動後の手動再開 → 不要
  （自動）/ モード切替時の「watch 停止 → 切替 → 再起動」→ 切替後に `make soak-agent-restart`
  （kickstart -k・スコープ / 凍結見張りの基準取り直し）。python3 / aws の実パス・PATH・
  `AWS_PROFILE` はインストール時のシェルから plist へ焼き込む（launchd 既定 PATH に homebrew が
  無いため。パスを変えたら再インストール）。インストールは既存のターミナル watch を検出すると
  中断（同一 JSONL への二重追記 = soak 実績の汚染防止）。ターミナル常駐（`make soak-watch-fp`）
  は代替/デバッグ用に温存。ログ = JSONL 従来どおり + `agent.out.log` / `agent.err.log`
  （`~/Library/Logs/TideSoak/`）。**導入実踏の知見（2026-07-25）**: launchd 直下では python3
  （homebrew）自身が TCC の責任プロセスになり、group defaults / DB stat が **Group Container
  保護（`kTCCServiceSystemPolicyAppData`・macOS 15+）** で拒否される — 初回スポーンの
  許可ダイアログを「許可」する（Terminal.app の既存許可は launchd には効かない・拒否すると
  設定解決 exit 2 → 60 秒スロットルの再スポーンループ・brew python 更新後は再許可の可能性）。
  aws CLI の SSO トークン更新 429 は周回単位で自己回復（watch ループは落ちない）。
  詳細 = `tools/soak/README.md`「launchd 常駐化」節。
- **watch 健全性通知（2026-08-03・Issue #94）**: #40 の 1 週間判定（2026-08-03 合格・記録 =
  `docs/09` #40 節と Issue #40 コメント）で、AWS 認証セッション失効
  （profile の `login_session` ≈ 12 時間）により watch が毎周回失敗し続けても無通知 =
  **観測空白が静かに発生**していたことが発覚（7 日中約 7 割が空白。launchd の KeepAlive は
  プロセス生存しか保証しない）。対処 = `--watch` 自身が周回の連続失敗を検出して macOS 通知
  （`WatchHealthNotifier`・連続 3 周回で初回通知・継続中は 1 時間ごと再通知・復帰時に回復通知
  1 回・osascript）。通知は可視化のみで周回継続・終了コードに影響しない。方式はユーザ確定
  （長期キー切替案より通知案を採用）— soak 監視は「唯一のバックアップ化」判断までの
  **フェーズ限定の足場**であり、認証運用（約 12 時間ごとの `aws login`）は継続する前提。
  詳細 = `tools/soak/README.md`「watch 健全性通知」節。
- **既存事象の記録（切替起因でない）**: 毎起動の `enforceTLSBucketPolicy on launch failed
  (non-fatal)` は、dev-tide に TLS 強制ポリシー（`TideDenyInsecureTransport`）が**適用済み**の
  まま、アプリの IAM 資格情報にポリシー読取権限が無いための自己修復チェック失敗（aws CLI で
  適用済みを確認・切替前 2026-07-24 から毎起動発生・実害なし）。→ **Issue #81 で解消
  （2026-07-25）**: `getBucketPolicy` の AccessDenied（`S3ErrorClassifier.isForbidden`）を
  `TLSPolicyStatus.checkDenied` として返し、呼び出し側（起動時 = `AppEnvironment` / セットアップ時 =
  ウィザード）は `.notice` へ降格。`putBucketPolicy` 到達後の AccessDenied（= ポリシー不在を確認した
  のに直せない実ドリフト）は従来どおり throw → `.error` 維持。

#### FP 版 Sync Activity = 拡張イベントの共有ストア軽量ログ（Issue #83・2026-07-26）

fpOnly はアプリが DB を開かない（凍結温存）ため DB 由来の Sync Activity / エラー履歴が縮退する
（B-1 当時の判断）。FP 拡張のイベントを App Group 共有ストアへ軽量ログし、既存の Sync Activity
ウィンドウで表示して可視性を復権した。設計判断 4 点（2026-07-26 ユーザ確定）: ① ストア形式 =
追記型 JSONL + サイズローテーション ② 記録範囲 = 書込系 + エラー + materialize 成功（evict 検出は
見送り）③ UI = 既存ウィンドウのソース差替 ④ 書き手 = 拡張プロセスのみ。

- **`FPEventLog`**（`TideCore/Storage/FPEventLog.swift`・actor）: 1 行 1 イベント JSON を
  `<App Group>/Library/Caches/Tide/fp-events-ext.jsonl` へ追記（best-effort = 失敗しても
  FP 操作は失敗させない）。2MB 到達で現行 → `.1` 退避（保持 = 現行 + 1 世代 ≒ 数千〜1 万件）。
  ファイル名の `-ext` は書き手識別子 — 将来アプリ側イベントを足す場合は**別ファイル**を増やし
  読み時マージする（同一ファイルへの多プロセス追記はしない・2026-07-26 ユーザ確定）。
  レコードは `timestamp` / `bucket` / `eventType`（`SyncLogEventType` の rawValue）/ `path` /
  `message` / `details`。拡張の DB 非接触は維持（GRDB 非依存の素のファイル）。security L19。
- **記録点**（`FileProviderExtension` の各コールバック + `completeCreate`）: 書込系成功 =
  created / uploaded / moved（dir move は件数付き）/ deleted（file / dir）→ upload / move /
  delete、materialize 成功 → download、競合（conflict copy 作成・正規パスはリモート勝ち）→
  conflict、除外（機密網 / symlink / `.syncignore` / 検証不能名・rename 除外含む）と削除拒否
  （remote changed / base unknown）→ info、catch 経路 → error（`CancellationError` は正常系な
  ので記録しない）。`SyncLogEventType` に `.move` を追加 — folderSync は move を一次イベントと
  して持たない（delete + upload に分解）ため DB 側には現れない。
- **UI（ソース差替）**: `SyncActivitySource` プロトコル（`SyncActivityModel.swift`）を挟み、
  folderSync = `DatabaseActivitySource`（従来どおり sync_log）/ fpOnly =
  `FPEventLogActivitySource`（`FPEventLog` 読み・DB / syncRoot 非接触 = 凍結温存を維持）。
  生成は `AppEnvironment.makeSyncActivitySource()`。ページング契約は `LocalDatabase.fetchLogs`
  と同一（id 降順・beforeId カーソル・limit 超過分で hasMore）。FP 側の id は時系列 index の
  合成で、reload（beforeId nil）時のスナップショットからページングする（読込の合間の追記で
  カーソルがずれない・追記の反映は Refresh）。ポップオーバーの「Sync Activity…」導線は fpOnly
  でも表示（`engine != nil || signaler != nil`）。フッタ注記はソースごとに差替
  （DB = 30 日自動削除 / FP = サイズ上限で古い順破棄）。**PR #90 レビュー対応 3 点**: ①
  フィルタチップの列挙はソースの `displayedEventTypes`（folderSync は move を一次イベントと
  して持たないため Moves チップを出さない）② FP 合成 id は reload を跨いで安定しない
  （ローテーション世代破棄で前詰め）ため、`hasStableIds = false` のソースは reload で選択を
  無条件解除（同値 id が別レコードを指したまま詳細ペインに出るのを防ぐ。DB は id 安定 =
  選択維持のまま）③ fpOnly の `FPEventLog.defaultURL()` 構築失敗（group container 不達の
  エッジ）は nil ソースにせず fileURL nil の縮退ソース = 空表示（「Run setup first…」の
  誤誘導にしない）。
- **読込時再検証**（L16 と同じ規約。表示専用 = path を FS 操作に使わないため**行単位破棄**で
  足りる）: 壊れ行（書き手が追記中の書きかけ末尾行を含む）スキップ・bucket 不一致 / 未知
  eventType / 不正 path（`validateRelativePath`）は行破棄・message / details は長さ上限で
  切る・肥大ファイル（> 2×maxBytes・改ざん前提）は読込ごと拒否。表示は従来どおり
  `Text(verbatim:)`（ローカライズ解決に流さない）。
- **回帰**: `FPEventLogTests`（往復 / ローテーション / 読込時再検証）・`SyncActivityModelTests`
  （DB / FP 両ソースのページング・フィルタ・reload スナップショット固定）。
- **実機受け入れ 2026-07-26 全項目パス**（受け入れ中に発生したバースト RMW 競合インシデントと
  治癒・知見 3 件の詳細記録 = `docs/09` M5 #83 節）。

#### boot fpOnly 固定 + Sync mode 設定 UI 撤去（v0.3.0 #96・2026-08-08）

v0.3.0「ユーザー目線からの folderSync 削除」第 1 段（設計原本 = `docs/09` v0.3.0 節）。
folderSync へ戻る経路を UI / defaults の両面から閉じる（動機 = 空フォルダ受理 → 全件 delete の
事故窓。詳細は docs/09 の危険知見）。

- **boot の無条件 fpOnly 化**: `launchEngineFromCurrentConfig` は syncMode を読まず常に
  `launchFPOnlySignalerFromCurrentConfig()` へ。**ゲートは関数内部**（呼出経路 = `bootstrap()` /
  `completeSetup` の両方を 1 点で塞ぐ・呼出側ゲート禁止 = PR #99 レビュー指摘 2）。folderSync
  起動本体は到達不能 private `launchFolderSyncEngineFromCurrentConfig()` へ改名温存
  （SyncEngine 一式のコンパイル維持・復活は git revert のみ = docs/09「revert 復帰ランブック」
  必須・物理削除は従来ゲート〈FP-only 無事故実績 + 2 台 soak 後〉据え置き）。
- **正規化書込**: `bootstrap()` の `LegacyStateMigrator` 直後・`setupCompleted` guard の前で
  `syncMode != .fpOnly` なら fpOnly を書く。`defaults write` の脱出口封鎖と、外部ツール契約キー
  （下記）の保存値恒久 fpOnly 化を同時に達成。
- **`ConfigStore.syncMode` = 外部ツール契約キーへ転生**: enum / プロパティ / `migratableKeys`
  掲載は温存・アプリは分岐のために読まない。読み手は `tools/soak/consistency_check.py` の
  4 箇所（突合ガード exit 2 / DBFreezeWatch 武装条件 / `mode:switched` / `mode:config-mismatch`）。
  キー廃止は観測の静かな縮退になるため不可。**スクリプト・Makefile・launchd 常駐 watch は
  無変更**（保存値 fpOnly 不変のため再インストール不要。例外 = factoryReset はキーを一時削除 →
  #97 の completeSetup 明示書込が窓を閉じる。factoryReset を挟んだら**再セットアップ完了後に**
  `make soak-agent-restart`〈不在窓中の restart は DB 凍結見張りが agent 生存期間中無音で
  非武装化〉）。
- **UI 撤去**: 設定画面の「Sync mode」セクション一式（Picker / 再起動案内 / FP 未有効警告 /
  `runningSyncMode`）と「Sync Folder」行（`LabeledContent`）を削除。FP セクション説明文を
  fpOnly 前提へ差替（「the sync folder keeps working alongside」を除去・**Disable = 全同期停止**を
  明記）。`MenuBarContent.secondaryActions` は「Open Tide in Finder」へ一本化（bootstrap 失敗時の
  else フォールバックだった「Open Sync Folder」を廃止 = #98 で消える `~/Tide` への導線を出さない）。
  一本化に伴い **`fileProviderEnabled` の取得を `signaler != nil` ガードの外へ移動**（PR #99
  再レビュー指摘 7）。disable は**既知の無効（`== false`）のみ**とし、未取得（nil = 取得中 or
  fileproviderd 無応答）は活性のまま — クリック時の `userVisibleURL()` が真実で、取れなければ
  実ホームの `~/Library/CloudStorage` を best-effort で開く縮退（唯一の Finder 導線を無音 no-op
  にも恒久 disable にもしない。PR #100 レビュー指摘 4 で `== true` 活性から変更。sandbox の LS が
  縮退パスを拒否する可能性は残るため成否をログ観測）。`openSyncFolder()` は参照ゼロになるため
  削除（UI コードは git revert で丸ごと戻せる = 温存対象はエンジン側のみ、の線引きどおり）。
- **xcstrings**: Sync mode 系 6 キー + 旧 FP 説明キー + `Open Sync Folder`（行ごと消滅で孤児化）を
  削除・新 FP 説明キーを追加（ja 訳・manual）。`Sync Folder` キーはウィザード step title と共有の
  ため温存（#97 で削除）。ポップオーバー用の `File Provider is not enabled — nothing is syncing.
  Enable it in Settings.` も温存。
- **テスト**: `ConfigStoreTests` の旧「folderSync = 安全側」セマンティクス 3 本（既定値 / 未知値
  フォールバック / reset クリア）を一旦削除 → **うち 2 本はレビュー対応で新セマンティクスの記述に
  変えて復活**（未知値/不在キー → `.folderSync` フォールバック = 正規化書込の load-bearing・
  reset のキー削除 = 不在窓モデルの前提。下記レビュー対応 ⑤ 参照）。最終的に消えているのは
  既定値テスト `testSyncModeDefaultsToFolderSync` の 1 本だけ。`testSyncModeRoundTrip` は
  リテラルのキー名・保存値 assert 付きで契約キーの往復保証として温存。
- **運用注意**: #96 マージ〜#97 マージの間は factoryReset / 再セットアップ禁止（旧ウィザードが
  フォルダを選ばせるが boot は fpOnly という過渡。データ危険は無いが踏まない）。
- **PR #100 レビュー対応（2026-08-08・7 件）**: ① 新規セットアップの FP 未有効沈黙窓 =
  **受容**（PR #99 設計レビューで確定済みの過渡・上記運用注意で禁止・#97 が正式解消）
  ② `completeSetup` に `syncMode = .fpOnly` の明示書込を**前倒し**（#97 予定の二重化。
  factoryReset → 同一セッション再セットアップで次回起動まで syncMode 不在 = DB 凍結見張りが
  静かに非武装、の窓を閉じる）③ seed `.syncignore` が fpOnly boot ではマニフェストへ届かない
  件と bookmark 発行 = **#97 参照の NOTE コメントを付記**（挙動変更なし・過渡は再セットアップ
  禁止でカバー）④ メニュー導線 = 上記のとおり nil 活性 + CloudStorage 縮退へ変更
  ⑤ キー不在/未知値 → `.folderSync` フォールバックのテスト復活（正規化書込の load-bearing =
  `?? .fpOnly` への「掃除」禁止を固定）⑥ 往復テストにリテラルのキー名・保存値 assert を追加
  （`defaults read` の生文字列を読む外部ツール契約の実固定）⑦ `SyncMode` enum doc を
  契約キーセマンティクスへ書換（property doc との矛盾解消）。
- **PR #100 再レビュー対応（2026-08-08・7 件）**: ① `FileProviderController.isEnabled()` を
  **`Bool?` 化**（throw = nil。「一時的な XPC 失敗」と「既知の未登録」を区別 — false 潰しだと
  fileproviderd 無応答で実在ドメインへの導線が誤 disable される。真偽が要る文脈は `== true` /
  `!= true` で倒す側を明示 = signal ガード / #82 観測は従来挙動維持）② 過渡窓の UI 導線
  （Open Setup Wizard / Factory reset ボタン）は**塞がない判断を明記** — ウィザードは
  bootstrap 失敗（Keychain 消失等）時の復旧経路のため disable は復旧を塞ぐ・単一ユーザ運用・
  禁止は docs / Issue 運用注意で担保（#97 で論点自体が消滅）③ completeSetup の syncMode 書込を
  **冒頭（throw し得る bookmark 発行 / Keychain 保存の前）へ移動**（途中失敗でも不在窓を
  無条件に閉じる・冪等）④ CloudStorage 縮退を `FileProviderController.userVisibleURLOrFallback()`
  へ移設（将来の呼び手が nil の無音挙動を再踏襲しない・「親 `CloudStorage/` に留める =
  `Tide-Tide` 名は OS が displayName から合成しパス恒常性の公開契約が無い」の理由をコメント化。
  LS 拒否の可能性は実機受け入れ項目で観測）⑤ `testResetClearsSyncMode` を新セマンティクスの
  記述（キー削除 → getter フォールバック → 明示書込で復帰、の不在窓モデル固定）で復活。
  completeSetup / bootstrap の配線ピンは XCTest ガード（実 S3 / Keychain 非接触）の制約で
  ユニットテスト不可 — #97 での維持は docs/09 とコード内コメントに明記 ⑥ 契約キー doc の
  「#97 以降」表現を前倒し済みへ修正 ⑦ テストの suite 生成 + teardown を `makeDefaults()` へ
  集約（重複ボイラープレート解消）。
- **実機受け入れ（2026-08-08・全 7 項目パス）**: fpOnly 起動ログ / 正規化実証（`defaults write`
  で folderSync → 起動時 Normalizing ログ → 保存値 fpOnly 復帰）/ `soak-check-fp` 整合 OK
  （manifest 1038 = s3 1038）+ フラグ無し exit 2 / 常駐 agent 継続稼働（再インストール不要の実証）/
  Settings ja・en の UI 撤去 + 新文言 / ポップオーバー導線一本化。**項目 7 の実測知見**:
  fileproviderd を SIGSTOP して「Open Tide in Finder」をクリックすると **XPC は throw せず
  ハングする**（30 秒超もタイムアウト無し）— 縮退フォールバック・primary とも非発火で無反応。
  SIGCONT で保留 XPC が完了し、正しい Finder（場所 → Tide）が遅れて開く（誤動作なし）。
  つまり縮退（CloudStorage open）の発火条件は「XPC が実際にエラーを**返す**状況」（デーモン
  再起動中等）に限られ、SIGSTOP 手段では **LS 拒否の成否は未検証のまま**（縮退コードは
  best-effort + `opened=` ログ観測の位置づけを維持。発火実例を観測したら成否を追記）。

#### ウィザード fpOnly ネイティブ化（v0.3.0 #97・2026-08-08）

v0.3.0 第 2 段（設計原本 = `docs/09` v0.3.0 節・Issue #97）。セットアップウィザードから
ローカル同期フォルダの概念を消し、「セットアップ完了 = Finder の『場所』に Tide が出て
dataless 一覧が見える」体験（クリーンインストール復旧の完成形）にする。#96 の運用注意
だった「factoryReset / 再セットアップ禁止」は本変更のマージで解除。

- **ステップ構成**: credentials → bucket → provisioning → **fileProvider**（旧 folder を置換）→
  done。fileProvider ステップは説明（Finder の「場所」に Tide が現れ、ファイルは開いた時に
  ダウンロード）+ `FileProviderController.isEnabled()` の現況表示（再セットアップ経路向け・
  nil = 取得失敗は表示しないだけで進行は妨げない）。**有効化ボタンは置かない** —
  「Start syncing」= `completeSetup` が enable を内包する。
- **`completeSetup(credentials:bucket:region:)` シグネチャ置換**（fpOnly 版の並置はしない）:
  `syncMode = .fpOnly` 明示書込（冒頭・#96 前倒し分の維持 = factoryReset 後の不在窓を閉じる）→
  `isBootstrapping` ガード（最初の suspension point より前）→ 旧 signaler stop（再レビュー ②）→
  ドメイン作り直し判定 + `disableForRecreation()`（レビュー指摘 1 / 再レビュー ①③）→
  Keychain 保存 → config 書込（bucket / region / setupCompleted）→ `.syncignore` seed
  （再レビュー ④）→ `FileProviderController.enable()`（既有効の再 add は成功/no-op。失敗は
  throw → ウィザードにエラー表示・設定は保存済みなので Settings の Enable ボタンでも回復可）→
  `launchEngineFromCurrentConfig()` + `bootstrapFailure = nil`。**順序が本質**: 保存前に enable
  すると拡張が未設定状態で起動してエラー列挙になり、enable 後に seed を置くと拡張の先行書込で
  新規バケット判定が誤り得る。security-scoped bookmark 発行と `syncRootPath` /
  `syncRootBookmark` 書込は削除（fpOnly に syncRoot 面が無い。security L1 追記）。
- **seed の S3 直書き化**: 新規バケット（`getIndex() == nil`）限定で
  `SyncIgnoreMatcher.defaultTemplate` を `files/.syncignore` へ PUT +
  `ManifestUpdater.updateFileEntry(base: nil)` 合流（`S3RestoreService` と同型の書込・best-effort
  非致命・確定点 signal で FP レプリカへ即時反映）。既存バケット参加時は作らない（従来どおり）。
  旧実装（ローカル同期フォルダへ書く）は fpOnly boot では誰も読まずマニフェストへ届かなかった
  （#96 の既知の過渡・PR #100 レビュー指摘 3）。
- **done 画面**: FP 前提の文言へ差替（既存バケットのデータは「プレースホルダとして表示・開いた時
  にダウンロード」）+「Open Tide in Finder」ボタン追加。scope 開始ロジックは
  `FileProviderController.openUserVisibleFolderInFinder()` へ抽出し、ポップオーバーと共用
  （B-2 受け入れで踏んだ scope 開始漏れバグの構造的再発防止）。
- **folder 系 UI の物理削除**: `@State syncRootPath` / `folderView` / `chooseFolder` /
  `validateSyncRoot` / done の Folder 行 / `applyImported` の syncRootPath 充填。温存の線引き =
  FSEvents「コード温存」の対象は folderSync 復帰資産（エンジン側）であり、ウィザード UI は
  git revert で丸ごと戻せるため削除してよい。再許可パネル文言キー（`Tide needs access…` /
  `Grant Access`）は温存デッド経路（`requestSyncRootAccessViaPanel`）が参照するため残す。
- **xcstrings**: folder 系キー一式 + `Sync Folder`（#96 から持ち越しの step title）+ 参照ゼロ
  だった旧 done 文言キー（`Setup complete. Tide will now sync your folder to S3.`）を削除・
  credentials の import 説明文を「bucket and region」へ是正・fileProvider ステップ / done の
  新キーを追加（ja 訳・`extractionState: manual`）。
- **設定 import/export（#29）の整合**: `connectionDiffers` から syncRootPath 比較を削除
  （bucket / region のみ。旧 export の死にキー値との差分で不要なウィザード誘導を出さない）・
  export 側は `syncRootPath = nil` を書く（`SettingsTransfer.Payload` のフィールド自体は
  optional のため schema v1 の decode 互換で温存・死にキーの削除済みパスを設定ファイルへ
  露出させない）・`DiagnosticsExporter` の「Sync folder:」行は fpOnly（engine 不在）では値を
  渡さず "—" 表示（folderSync デッド経路が生きる revert 時のみ従来どおり）。Settings の
  export/import 説明文・import 完了メッセージからも folder 言及を除去。
- **設定画面「.syncignore」セクションの静的案内置換**（ユーザ確定 2026-08-08・PR #99 レビュー
  指摘 4）: パターン一覧（ソース = `engine.activeIgnorePatterns`・fpOnly では engine 恒常 nil の
  ため常に「No .syncignore patterns」= パターンが実効なのに空表示の誤情報）を撤去し、
  「除外パターンは Tide フォルダ（Finder サイドバー「場所」の Tide）内の `.syncignore` で管理
  （新規ファイルにのみ適用）」の静的テキスト +「Open Tide in Finder」導線へ置換（「同期フォルダ /
  Sync Folder」呼称は使わない）。実効は FP createItem 側（`ManifestIgnoreCache`）で維持・
  一覧表示の復権が必要になったら別 Issue。「Excluded patterns (built-in)」セクションは静的定数
  ソースのため不変。
- **PR #101 レビュー対応（2026-08-08・2 件）**: ① **別バケットへの切替は `completeSetup` が
  FP ドメインを作り直す**（disable → enable。CONFIRMED）— `enable()` の既有効 no-op はレプリカを
  温存するため旧バケット由来の保留書込（dirty item）が残り、拡張は書込時に共有 config から
  bucket を読む（`ExtensionServices.fromSharedConfig`）ので fileproviderd の再試行がそれらを
  新バケットへ静かに混入させる。**比較は config 上書き前・disable 失敗は config 未更新のまま
  throw**（先に config を書くと失敗後のリトライが「同一バケット」に見えて作り直しがスキップされ
  混入窓が残る）。disable は保留書込を破棄する（PR #61 記録）が旧内容を新バケットへ流すより
  安全側。隣接論点として **completeSetup は launch 前に旧 signaler を stop**（止めないと旧
  インスタンスの pollTask が旧設定の index を HEAD し続ける。配置は再レビュー ② で冒頭へ是正）。
  同一バケットの再セットアップは従来どおりレプリカ温存（再 add no-op）。② signal 配線付き
  `ManifestUpdater` の構築を `makeSignalingManifestUpdater(store:deviceId:)` ファクトリへ集約
  （S3 内復元 / seed 共用・呼び出し側ごとの手書き配線による signal 漏れ〈PR #56 レビュー ④ の
  警戒〉を構造的に防止）。
- **PR #101 再レビュー対応（2026-08-08・6 件）**: ① 切替 disable 成功後の途中失敗（Keychain
  保存 / enable の throw）で FP ドメインが**補償なしで消える**件（CONFIRMED/High。`disable()` は
  pending-add フラグも消すため、boot の migrate も launchFPOnlySignaler も re-add せず
  「再起動しても直らない無音の同期停止」= 回復は Settings → Enable の発見頼みだった）→
  `FileProviderController.disableForRecreation()` 新設 = **pending-add フラグを立ててから
  remove**（`migrateStaleDomainsIfNeeded` と同順序 = remove 後の失敗/クラッシュでも「有効化
  済み」意図が消えない）。途中失敗でも次回起動の migrate が add を再開する。`enable()` は
  成功時に同フラグを消す（確定点で対称）。明示的無効化（factoryReset / Settings の Disable =
  再有効化の意図なし）は従来どおり `disable()` ② 旧 signaler の stop が enable の**後ろ**に
  あり、enable 失敗時に旧バケット束縛（構築時 `[s3]` キャプチャ）の pollTask が生き残る +
  bootstrap() の signaler != nil 早期 return & bootstrapFailure クリアで「健康に見えたまま
  新バケットの signaler が立たない」固着（CONFIRMED/High）→ stop を completeSetup 冒頭
  （isBootstrapping 直後・最初の throw より前）へ移動 ③ factoryReset の握りつぶされた
  disable（`try?`）通過後は bucketName 不在 × 生存ドメイン = 素性不明レプリカで混入窓が
  再開する件（CONFIRMED/Medium）→ 作り直し判定を観測状態併用へ: 旧 bucketName 不在時は
  `isEnabled() != false`（生存 / 不明）で作り直し（不明を温存側に倒すと「isEnabled 失敗 →
  直後の enable 成功」で素性不明レプリカが残るため作り直し側）④ seed の新規バケット判定
  （getIndex == nil）が enable の後ろで、live になった拡張の先行 createItem により既存側へ
  誤判定 → seed 無音スキップし得る件（PLAUSIBLE/Low）→ **seed を enable 前へ移動**（seed は
  S3 のみ・確定点 signal は未登録ドメインで no-op・enable 後の初回列挙が拾う。PUT 成功後の
  updateFileEntry 失敗 = 孤児は benign と検証済み〈後追い作成は remote nil → .proceed で
  無衝突・再セットアップは index 不在のまま再試行〉）⑤ Settings「.syncignore」セクションの
  「Open Tide in Finder」へメニューバー行と同じ `.disabled(fileProviderEnabled == false)` を
  付与（既知の無効時に素の CloudStorage が開く案内矛盾の防止）⑥ bookmark 発行削除と矛盾する
  残存記述の是正: 本ファイル App Sandbox 節（#97 読み替え注記）/ docs/01 起動フロー図
  （「同期フォルダ選択」→「File Provider ドメイン有効化」）/ docs/06（bookmark 発行の世代注記 +
  entitlement の現用途）/ `ConfigStore.syncRootPath`・`SettingsTransfer` の「正規の書き手 =
  completeSetup」コメント（書き手は `resolveSyncRootAccess` の追随更新のみへ）。
- **PR #101 三次レビュー対応（2026-08-08・2 件）**: ① factoryReset が pending-add フラグを
  残し得る件（PLAUSIBLE/Low。`disableForRecreation` → 途中失敗でフラグ残置 → factoryReset の
  `disable()` が removeAllDomains の throw を呼び出し側 `try?` で握りつぶすとフラグ生存 →
  `ConfigStore.reset` の消し込み対象外のため、全消し済みアプリで次回起動の migrate
  〈setupCompleted ゲートより前に走る〉が FP ドメインを無言 re-add = 未設定拡張のエラー列挙）→
  `disable()` のフラグ除去を removeAllDomains の**前**へ移動（明示的無効化の意図は remove
  失敗でも勝つ・remove 失敗ならドメイン残存なのでフラグ無しでも実害なし・Disable 再操作で
  回復可）② 本節 completeSetup bullet の記載順序が旧実装のままだった件（docs のみ）→
  最終実装の順序（stop 冒頭化・seed の enable 前倒し込み）へ是正。
- **PR #101 四次レビュー対応（2026-08-08・8 件 = 修正 6 + 記録 2）**: ① 未設定アプリでの
  pending-add フラグ残置（disableForRecreation → Keychain 保存等で中断 → setupCompleted
  未確定のままフラグ生存 → 次回起動の migrate〈setupCompleted ゲートより前〉が未設定拡張を
  無言 re-add・CONFIRMED）→ migrate の pending-add 再開 add を **`ConfigStore().setupCompleted`
  でゲート** + 未設定ならフラグ回収（正規セットアップは enable() が無条件 add するため
  フラグ無しで困らない）② バケット切替（破壊的 recreation）時にウィザードの緑チェック
  「already enabled」が継続性を誤示唆（CONFIRMED）→ `isBucketSwitch`（config 上書き前の旧値
  比較 = completeSetup と同じ不変条件）で**警告表示に差替**（「切替はフォルダ作り直し・
  未アップロード変更は破棄」）③ bootstrap の fire-and-forget migrate と completeSetup の
  recreation 窓が非直列（stale スナップショットの resume がフラグ誤回収 / 旧設定 re-add・
  PLAUSIBLE）→ **`migrationTask` ハンドルを保持し completeSetup が disableForRecreation 前に
  await**（cancel では XPC 待ちの本体を止められないため await）④ ウィザード経由 enable 後に
  開きっぱなしの Settings が stale（CONFIRMED/nit）→ `AppEnvironment.fileProviderStateVersion`
  カウンタ（completeSetup が defer で成否問わずインクリメント）+ Settings 側 `.task(id:)` 再取得
  ⑤ `getIndex() == nil` ≠「新規バケット」（index 欠損 × shards 生存の損傷バケットで 1 シャード
  index を製造）= 全書き手共有の既存挙動 → **修正不要と合意・docs/09 バックログへ記録**
  ⑥ `ManifestFileEntry` 手組みの 4 箇所目コピー → **follow-up 合意・docs/09 バックログへ記録**
  ⑦ 「schema v1 decode 互換のため温存」コメントが事実誤り（JSONDecoder は未知キーを無視）→
  実際の理由（folderSync revert 資産）へ書換（テスト側の複製コメントも）⑧ Diagnostics の
  `engine != nil` プロキシ（恒真 nil のデッド分岐・モードの代理として不正確）→ SettingsTransfer
  と同じ素の nil へ統一（revert 時は git がこの行ごと戻す）。
- **PR #101 五次レビュー対応（2026-08-08・3 件）**: ① bootstrap 再実行（未セットアップ状態は
  ポップオーバーを開くたび本体が走る）で `migrationTask` が単純上書きされ、completeSetup が
  最新 1 本しか await できない（XPC 停滞中の**孤児 migrate** が stale スナップショットで
  resume → disableForRecreation 直後の pending-add フラグを誤回収 / seed 前の早期 add・High）→
  spawn を**前回タスクへのチェーン**（新 Task が先頭で `await previous?.value`）へ変更 =
  最新ハンドルの await が推移的に全先行タスクを待つ ② ウィザードの切替警告が作り直し判定の
  枝 (a)（バケット比較）しか複製しておらず、枝 (b)（bucketName 不在 × 生存ドメイン = factoryReset
  の swallowed disable 後）で緑チェックが破壊的 recreation を誤示唆（Medium）→ 判定を
  `AppEnvironment.willRecreateDomain(forBucket:)` へ抽出して completeSetup とウィザード表示で
  **共有**（枝の増減に UI が自動追従）・警告文言も枝非依存の汎用形（「このセットアップで Tide
  フォルダは作り直されます…」）へ差替 ③ ウィザードの `fileProviderAlreadyEnabled` に更新 id が
  無く、completeSetup 部分失敗（disableForRecreation 済み → enable throw）後にエラー表示の隣へ
  stale な緑チェックが残る（Low）→ Settings と同じ `.task(id: env.fileProviderStateVersion)` 化
  （② の `willRecreateDomain` 再取得も同 task に同居）。
- **PR #101 六次レビュー対応（2026-08-08・6 件）**: ① 破壊的 recreation 警告が
  `fileProviderAlreadyEnabled == true` の内側で、isEnabled nil（fileproviderd 無応答）だと無警告
  破棄になる（High）→ 警告を enabled 判定の外へ（`willRecreateDomain == true && enabled != false`
  で表示 = 不明も警告側・既知の未登録のみ除外〈破棄対象が無い〉・緑チェックは
  `enabled == true && willRecreate == false` のみ）② `.fileProvider` の `canAdvance` 無条件 true
  で probe 解決前に Return（.defaultAction）が警告未レンダリングのまま completeSetup へ到達
  （High）→ `willRecreateDomain != nil` をゲートに ③ `fileProviderStateVersion` のバンプが
  completeSetup のみ + MenuBarContent 未購読（Medium）→ factoryReset に defer バンプ・Settings の
  Enable/Disable は新設 `noteFileProviderDomainStateChanged()` 経由・ポップオーバーの
  `fileProviderEnabled` 取得を `.task(id:)` 購読へ（セットアップ成功直後の赤バナー残置解消。
  値の完全集約〈observable 1 本〉はカウンタ = 無効化バスで実害が閉じるため見送り）
  ④ factoryReset が migrate と非直列（stale resume がリセット済みアプリへ孤児ドメイン re-add /
  フラグ残置・Medium）→ 冒頭で `await migrationTask?.value` ⑤ 五次のチェーン方式は未セットアップ
  中のポップオーバー再訪ごとに無限連鎖し completeSetup がチェーン全長を await（Low）→
  **実行中は再利用・完了時に自己解放**（同時 1 本・再試行は完了後の次回 bootstrap が担う）
  ⑥ クリーンインストール分岐に enable 失敗の再起動横断リトライが無い（再作成分岐と非対称・Low）→
  `enable()` が add の**前**に pending-add フラグを立てる（成功時クリア・migrate の
  setupCompleted ゲート + 未設定回収と組合せで全分岐対称の自己修復）。
- **PR #101 七次レビュー対応（2026-08-09・7 件 = 修正 6 + バックログ 1）**: ① Back 再入時の
  stale `@State` が probe ゲート（六次②）を素通しにする（High — 前回訪問の非 nil 値が XPC
  往復中の窓で canAdvance を満たし、bucket 変更後の Return が警告未レンダリングのまま
  disableForRecreation へ到達）→ `.task` 本体の先頭（await より前）で両 `@State` を nil リセット
  ② factoryReset に `isBootstrapping` ガードが無く `disable()` の XPC 窓で bootstrap が割り込める
  （Medium — ドレイン済みのはずの migrationTask 新規 spawn = 六次④の再開 / 消される直前の
  config・Keychain で signaler 再起動）→ completeSetup と同じガードを冒頭に + migrate 自己解放を
  **世代番号検査付き**に（Task は値型で identity 比較不可のため `migrationGeneration` で代替）
  ③ Settings の Enable/Disable だけ migrate ドレイン規約の外（Low）→ `drainDomainMigration()`
  共通チョークポイント + `enableFileProviderDomain()` / `disableFileProviderDomain()` ラッパを
  AppEnvironment に新設し 3 変更点（completeSetup / factoryReset / Settings）で統一 ④ doc
  コメントの取り違え（willRecreateDomain の契約が noteFileProviderDomainStateChanged に付随・
  Nit）→ 是正 ⑤ probe が isEnabled を 2 回叩き警告条件が異時点 2 スナップショットの合成
  （Cleanup）→ `probeDomainRecreation(forBucket:) -> (recreate, enabled)` の**単一 probe** へ統合
  （completeSetup は recreate 側のみ使用・XPC 1 往復削減）⑥ `userVisibleURLOrFallback` を
  private 化（呼び出しは scope 開始込みの `openUserVisibleFolderInFinder()` に一本化済み・
  scope 開始漏れの再導入扉を閉じる）⑦ pending-add フラグの命令的ステートマシン化（4 箇所分散）→
  「望ましい FP 状態 + 単一 reconcile」への宣言的リファクタを docs/09 バックログへ（本 PR
  実施不要と合意）。
- **PR #101 八次レビュー対応（2026-08-09・6 件）**: ① probe の task id に bucket が含まれず、
  fileProvider ステップ滞在中の設定インポート（ルートの .onChange は滞在ステップ非依存で発火し
  bucket をその場で書き換える）で stale 緑チェック + 活性ボタンのまま無警告の破壊的作り直しに
  到達できる（High）→ **task id を `"\(version)|\(bucket)"` の複合キー化**（bucket 変化 =
  nil リセット + 再 probe）② Enable/Disable ラッパに completeSetup / factoryReset との相互排他が
  無く、factoryReset の disable XPC 窓で Enable を押すと remove → add の順で「全消し済みアプリ +
  生きたドメイン + フラグ無し」（migrate は staleDomains 空 × フラグ無しで即 return = 四次①の
  ゲートに到達しない）に至る（High）→ **ラッパが isBootstrapping を check/set**（進行中は
  SyncError で拒否 — 待たせて後から実行すると意味が変わるため直列化でなく拒否）+ 対称面として
  completeSetup 冒頭にも busy ガード（syncMode 書込だけは例外的にガード前 = 不在窓を無条件に
  閉じる既存不変条件）・factoryReset は throw 不能のためログ + no-op（設定が残るので再押下で
  完遂可）③ `drainDomainMigration` の無条件 `migrationTask = nil` が resume 窓で spawn された
  新タスクを孤児化（Medium）→ タスク末尾の自己解放と同じ**世代検査**を drain 側にも ④ seed の
  新規バケット判定が「index 欠落 × shards 生存」の損傷バケットで誤爆（カスタム .syncignore の
  最新版置換 + 1 シャード index 新造で DRIFT を WARN へ格下げ・Low）→ **seed 前に
  `.tide/shards/` の空プローブ**（`listObjectVersions(maxKeys: 1)`・live 版 / delete marker の
  いずれかが見えたら seed しない）⑤ 実在しないメソッド名（willRecreateDomain）へのコメント参照 →
  probeDomainRecreation へ是正 ⑥ Enable/Disable 押下ごとの isEnabled XPC 二重実行 + version
  更新が呼び出し側任せ（Low）→ ラッパ内 `defer { fileProviderStateVersion += 1 }` へ移し、View の
  明示 fetch と `noteFileProviderDomainStateChanged()`（呼び手ゼロ化）を削除。
- **PR #101 九次レビュー対応（2026-08-09・7 件）**: ① factoryReset の busy スキップが「成功」に
  見える（呼び出し側が無条件 dismiss・High）→ `@discardableResult func factoryReset() async ->
  Bool` 化 + Settings は成功時のみ dismiss・スキップ時は案内表示（`resetMessage`）② 旧
  `isBootstrapping` の二役（起動中 / ドメイン変更 mutex）による誤拒否・無音ドロップ（High）→
  **`setupGate = RemoteOpGate`（既存型の再利用）へ置換**。取得セマンティクスを呼び出し元の意味で
  使い分け: bootstrap = tryAcquire（busy なら引く・ポップオーバー再訪で再試行）/
  **completeSetup = acquire（FIFO 待ち — bootstrap 起動や Enable の完了を待ってから実行して
  意味が変わらないため、拒否でなく直列化 = 誤拒否解消）**/ factoryReset・Enable・Disable =
  tryAcquire で拒否（待たせて後から実行すると意味が変わる操作）。`isBootstrapping` は削除
  ③ seed の部分失敗（shard 確定 → index 失敗 = #91 系）が握りつぶされ、八次④の shards probe が
  リトライを恒久封鎖（既定除外の無い新規バケットが静かに稼働・High）→ `updateFileEntry` を
  **1 回だけ即時リトライ**（再実行は alreadyUpToDate 経路 → repairIndexDeclarationIfStale が
  index 宣言を治癒。両方失敗の残余は best-effort の範囲でログ）④ 損傷バケット probe の逆側
  （`files/` 生存 × `.tide/` 全損）でカスタム `.syncignore` を既定テンプレートで置換し得る
  （Medium）→ `files/` プレフィックスの空プローブを追加（何か見えたら seed しない）
  ⑤ migrate の setupCompleted ゲートが pending-add 分岐のみで stale 分岐は未設定アプリでも add
  していた（Medium）→ ゲートを stale 分岐へも拡大（未設定時は stale **除去のみ**・add と
  フラグ set をしない）⑥ 未セットアップでも Settings の Enable が通り設定なしドメイン + 偽の
  破壊警告になる（Medium）→ enable ラッパに `setupCompleted` ガード（**disable 側は意図的に
  ガードなし** = 全消し済みアプリに生き残ったドメインの手動回復導線）⑦ probe 解決に無期限依存で
  ハング時に進行ゲートが理由不明のまま閉じ続ける（Low）→ 「確認中…」インジケータ + 10 秒で
  「不明 = 作り直し側」へのタイムアウトフォールバック（警告表示側 = 安全・probe が後から返れば
  実値で上書き）。
- **PR #101 十次レビュー対応（2026-08-09・7 件 = 修正 6 + バックログ 1）**: ① completeSetup が
  setupGate 保持のまま無界の fileproviderd XPC を await し、ハング時に全ライフサイクル操作が
  再起動まで固着（九次のゲート統一が爆風半径を広げた・High）→ **`FileProviderController` に
  `boundedXPC`（10 秒・一度きり resume の continuation レース）を新設**し、ゲート保持区間から
  届く全 XPC（isEnabled の domains() / enable の add / disable・disableForRecreation の
  removeAll / migrate 内の domains・remove・add）を有界化。TaskGroup はスコープ終了時に
  parked child を待つため不採用。timeout しても下層 XPC は中断されない（後着完了が無害な冪等
  add/remove・読み取りのみを通す規約）。`userVisibleURL` は意図的に非有界（ゲート外・#96 実測 =
  後着で正しく開く）② syncMode のゲート前書込が FIFO 待機中の factoryReset に消されると再書込
  されない（Medium）→ acquire 後に冪等再書込（ゲート前の書込は throw 前保証として温存）
  ③ 10 秒フォールバック Task が .task 再起動をまたいで孤児化し新サイクルで早期発火（Low）→
  `probeGeneration` の自世代検査 ④ `.task(id:) { isEnabled }` 3 面の await 後キャンセル検査
  欠如（逆順 resume の stale 書き戻し・Low）→ `guard !Task.isCancelled` を 3 箇所へ（enabled
  状態の AppEnvironment 集約案は docs/09 の宣言的リファクタへ合流）⑤ `migrationGeneration` は
  setupGate 不変条件下で証明可能に不活性（Cleanup）→ 削除し、spawn/drain の「必ずゲート下」
  不変条件を doc へ（無条件 nil に戻す）⑥ Enable/Disable ラッパの逐語重複（Nit）→
  `withDomainLifecycleGate(_:)` へ集約（busy 文字列も 1 箇所化・`.notConfigured` 流用の備忘は
  現状実害なしのため据え置き）⑦ probe `.task` の await 後キャンセル検査（High）→
  suggestion どおり `guard !Task.isCancelled` を挿入（設定インポートの逆順 XPC 応答で stale
  判定が新 probe を上書きする無警告破壊経路を封鎖）。

##### 実機受け入れ（2026-08-11・全項目パス）

Issue #97 本文のチェックリスト（9 項目 + 追補 7b〜7d）を dev バケットで全消化し合格。要点:

- **seed の S3 直書き**: 新規バケット経路で `files/.syncignore` + index/shard の整合を実測
  （entry に sha256/size/versionId 完備）。既存バケット合流では非発動（`.syncignore` の
  版履歴に新規 PUT なし）を確認。
- **書込スモーク**: FP レプリカでの作成/編集/削除が各約 3 秒で S3 往復・削除後のシャード
  後始末正常・`soak-check-fp` 整合 OK。
- **エラー表示 UI と `boundedXPC`（十次指摘 1）を fileproviderd SIGSTOP で実機実証**:
  「同期を開始」→ 10 秒きっかりで `removeAllDomains() timed out — fileproviderd is not
  responding` の赤エラーがウィザードに表示・アプリは無ハング・SIGCONT 後の再実行で成功
  （pending-add フラグ経由の自己修復設計どおり）。なお**拡張トグル OFF では `add(domain)` が
  成功してしまいエラー経路は発火しない**（チェックリスト項目 6 の期待側が誤り → Issue #103）。
- **バケット切替（7b）**: fileProvider ステップのオレンジ警告 →「Recreating File Provider
  domain」→「domains removed for recreation (pending re-add)」→「File Provider domain
  added」の正規ログ列 → レプリカが切替先バケット内容と完全一致（1038 件・双方向差分ゼロ =
  旧バケット由来の残存なし）。
- 進行ゲート（7d・Return 連打 / Back → bucket 変更 → 再入の一瞬 disabled）・UI 追随
  （7c・Settings を開いたまま FP セクションが有効表示へ・ポップオーバー赤バナー消滅）・
  import 誘導（bucket/region のみ事前充填・旧 export の syncRootPath は無視）・ja/en 文言、
  いずれもパス。
- **発見バグ 2 群は Issue 化（いずれも #97 リグレッションではない・マージ非阻害と判断）**:
  **#102** = ウィザード窓が完了後も `@State` を保持（done 出っぱなし / 同一セッションの
  import 誘導が見かけ上無反応・アプリ再起動で回避可 → **修正済み 2026-08-15**・後述
  「ウィザードの状態リセット」節）。**#103** = FP 拡張トグル OFF を検出
  できず緑表示のまま無音停止（`domains()` ベース検出が現 OS で不成立。#82 受け入れ時は機能
  → OS 挙動変化が濃厚。アプリ内 Disable の domain 除去経路では赤バナー正常 →
  **修正 2026-08-15**・後述「FP 拡張トグル OFF の検出」節）。
- 副次知見: soak launchd agent の plist が消失していた（原因不明・`soak-agent-install` で
  復旧・常駐再開済み）。

#### FP レジストリのドメイン epoch リセット（Issue #104・2026-08-12）

ドメイン作り直し（Disable/Enable・バケット切替・factoryReset）の後、**作り直し前に一度でも
バッジ報告済みだったパスは再実体化してもバッジ（#65）が二度と点灯しない**固着の恒久対処
（#97 受け入れの複数回作り直しで顕在化・2026-08-12 実機確認）。

- **機序**: バッジ配信は live（fileproviderd の実体化セット）と reported
  （`fileprovider-materialized.json` = `PersistedPathSet`）の**差分**だけを working set の
  enumerateChanges で配る設計（#65）。作り直しはダエモン側の item 記録（バッジ含む）を白紙化
  するが App Group Caches のレジストリは残存する。残存 reported に載るパスは再実体化すると
  live と reported の**両方**に現れ = 差分に出ず、バッジ ON が新レプリカへ一度も配信されない。
  `replace` の前進は非 live の stale 分だけを削ぎ落とし、live 再掲載分は「報告済み」のまま
  残す = 永久固着（バッジ節の受け入れ知見「stale reported → 自己修復」は消灯方向のみで、
  点灯方向のこの穴を見えなくしていた）。
- **対処 = ドメイン epoch（レジストリ削除ではなく世代マーカー・ユーザ確定 2026-08-12）**:
  アプリがドメイン除去（= レプリカ破棄）のたびに group defaults の
  `ConfigStore.fileProviderDomainEpoch`（ランダム UUID）を `bumpFileProviderDomainEpoch()` で
  進め、拡張のレジストリ 3 本（実体化バッジ報告済み / 仮想フォルダ温存 / 除外後始末予約）は
  **構築時に capture した epoch** で payload をスタンプ・読込時に現行値と不一致なら全体破棄
  （bucket 不一致と同じ安全側 = 空集合）。schemaVersion は 1 → 2（epoch フィールド追加）。
  - **capture 意味論が load-bearing**: アプリの bump 後に生き残りの旧拡張プロセスが遅延
    persist しても旧 epoch でスタンプされるため、次回読込で自動破棄される —「書き手 = 拡張 /
    消し手 = アプリ」の別プロセス削除レースをファイル削除なしで構造的に解消する（アプリ側から
    レジストリファイルを unlink する案は、atomic 全書きの遅延 persist が stale 内容を復活させる
    レース窓が残るため不採用）。
  - **bump は pending 予約 → remove 成功後に確定**（`removeAllDomainsInvalidatingRegistries` =
    除去のチョークポイント。当初の「remove 前に bump」は PR #106 レビュー指摘 1・2 で棄却）:
    ① **先 bump にしない**（指摘 2）— bump → remove の順だと remove XPC 窓（最大 10 秒）で
    fileproviderd が生成した新しい拡張インスタンスが**新 epoch を capture** し、死にゆく
    レプリカの実体化セットを新 epoch でスタンプし得る（作り直し後の新レプリカがそれを有効値と
    して読み #104 が再発）。remove 成功後なら旧レプリカの全書き手は旧 epoch capture 済みで
    遅延 persist ごと無効化される。② **remove 失敗（throw）では bump しない**（指摘 1）—
    timeout（fileproviderd 無応答）は日常的な失敗モードでレプリカは生きたまま使われ続ける
    可能性が高く、そこで bump すると健全なレプリカから仮想フォルダの存在根拠（レジストリが
    唯一）を奪い、`item(for:)` の noSuchItem → デーモン掃除で**ユーザの空フォルダが実際に
    消える**（= cosmetic ではない。除外後始末の予約も `.rejectedRemoteChanged` で失敗し続ける）。
    ③ **pending の回収**: remove 成功 → commit 前のクラッシュ / timeout 中断分は、次回起動の
    `migrateStaleDomainsIfNeeded` 冒頭が**ドメイン実在の観測**で確定（不在 = 除去は完了して
    いた → bump）または取り下げ（実在 = remove 真失敗でレプリカ生存 → 生きたレジストリを守る。
    観測後に後着 remove が完了する極小窓は容認 = Disable → Enable の再操作で回復可）。
    `enable()` も add の**前**に pending を確定する（「Disable timeout → 後着で remove 完了 →
    Enable」の並びで新レプリカが旧レジストリを有効値として読むのを防ぐ。レプリカが実は生存して
    いた場合の喪失は、Disable → Enable = ユーザ意図の作り直しサイクルとして容認・有界）。
  - **除去経路は必ずチョークポイント経由**（指摘 3）: `disable()` / `disableForRecreation()` は
    `removeAllDomainsInvalidatingRegistries` を通す（素の `removeAllDomains()` 直呼びは #104
    再発の扉。重複していた 2 関数の remove 本体もここに畳み込み）。`migrateStaleDomainsIfNeeded`
    の現行ドメイン再作成分岐は per-domain remove のため同ヘルパーを使わないが、同じ
    pending → commit 順序を守る（**`!hasCurrent` のときだけ**予約 — hasCurrent なら per-domain
    remove は stale "poc" だけを外し現行レプリカは温存されるため bump しない。確定は add より
    **前** = 後だと新レプリカの拡張が旧 epoch を capture する）。
  - **姉妹レジストリも対象 = 3 本すべて（ユーザ確定 2026-08-12）**: stale 掲載は、仮想フォルダ =
    消えた dir の空フォルダ合成（レジストリの本来目的「旧 dir 復活防止」と逆向き）、除外後始末 =
    死んだレプリカ由来の削除受理予約、として害にしかならず、作り直し後に失うものはない
    （レプリカ破棄で仮想フォルダ実体も除外 item も消えている）。`FPEventLog` はレプリカ状態と
    無関係な履歴のため対象外。
- **v1 payload は schemaVersion 不一致で一度だけ全体破棄される** = 既存環境の stale レジストリ
  （実機の固着）が**アプリ更新だけで自己治癒**する（レジストリファイルの手動削除は不要）。
  本修正は item スキーマ / capabilities に触れないため、適用にドメイン作り直しは不要。
- **既カバーだった経路（コード確認の記録）**: factoryReset は App Group Caches をディレクトリ
  ごと削除するためレジストリも消える。バケット切替は payload の bucket キー不一致で読込時
  全破棄。実際に踏む穴は「**同一バケットの Disable → Enable**」（= capabilities 変更の正規手順
  そのもの）と migrate の作り直し分岐だった。
- **観測性**（PR #106 レビュー指摘 5）: アプリ側の bump / 予約取り下げ（notice）に加え、拡張が
  capture した epoch 値（`ExtensionServices` 構築時）と `PersistedPathSet` の epoch 不一致破棄も
  notice（永続）でログする — group defaults のプロセス間伝播にタイミング保証は無く、stale
  capture が起きたとき症状（バッジ不点灯 / 仮想フォルダ消失）から本機構へ辿る手掛かりを残す。
  値はローカル生成のランダム UUID・ファイル名は固定レジストリ名のためどちらも `.public`
  （アプリ側ログと相関可能）。
- 回帰は `PersistedPathSetTests`（epoch 不一致 / nil 片側 / capture 遅延 persist / v1 破棄）+
  `ConfigStoreTests`（bump の前進 / reset 非対象・`migratableKeys` 非掲載の固定 = レビュー指摘 4
  〈掲載すると `LegacyStateMigrator` が別マシン由来 epoch を持ち込み生きたレジストリを無言
  全破棄する〉）。

#### evict 解放 =「ダウンロードを削除」（Issue #105・2026-08-12）

Finder の「ダウンロードを削除」（Remove Download = オンラインのみ化）がコンテクストメニューに
出ない件（`.allowsEvicting` 未付与 = 未実装・regression ではない）への対応。
`FileProviderItem.capabilities` へ `.allowsEvicting` を追加した。Files-on-Demand 運用の基本操作で、
Keep Downloaded（#40 の残フェーズ）の対向操作。

- **対象 = file + dir（root 除く）**（ユーザ確定 2026-08-12）: dir の evict はダエモンが配下の
  実体化済みファイルをまとめて evict するだけ（Dropbox 等と同じフォルダ単位 UX）。root は
  「削除・改名・移動不可」の既存保守姿勢に合わせ除外 — root evict = 全量オンラインのみ化は
  Keep Downloaded ピンとの相互作用が未検証のため。
- **拡張側の追加コールバックは不要（見込み・実機受け入れで確認）**: evict はダエモン側処理。
  バッジ消灯は既存の `materializedItemsDidChange` → 観測 → badge-only 配信経路（#65 の唯一の
  消灯検知経路）が拾う。
- **適用にはドメイン作り直しが必要**（capabilities 変更は既存レプリカへ自動反映されない =
  5-3 受け入れ知見①・正規手順 = アプリ設定の Disable → Enable）。作り直し前のレジストリ 3 本は
  #104 の epoch リセットが破棄する（本件が #104 恒久対処後の最初の実運用作り直し = 点灯方向の
  実地確認を兼ねる）。作り直しでレプリカ全量が dataless 化する（実体は開けば再取得・S3 側は
  無事・#97 受け入れ時の実測 = 1,055 中 1,026 ファイル）。
- **既知の注意（実機受け入れで観察）**: ① Finder プレビューペイン表示中の evict は EBUSY で
  失敗し得る（#65 受け入れ知見・OS 挙動）。② #93（rename 後の版スタンプ stale 固着 =
  `isMostRecentVersionDownloaded = 0`）の item は、ダエモンが「最新版未取得」とみなして evict を
  拒否する可能性がある（未検証の仮説・観察対象）。③ dir の evict は配下の**ローカルのみ
  データ**（`ExcludedFromSync` 温存分 = 機密網 / symlink / `.syncignore` 該当ファイル、および
  仮想フォルダ）を含むサブツリーにも及ぶ（PR #107 レビュー指摘 1）。これらは S3 にも
  マニフェストにも存在せず、実体まで破棄されると**復元不能**（fpOnly では DB も凍結）。
  ダエモンは未同期 item の evict を拒否する見込み（NonEvictable 系）だが未検証のため、
  受け入れで「除外ファイルを含む dir の evict → 該当ファイル温存」を必ず確認する。
- **実機受け入れ（2026-08-12・dev バケット・全項目パス）**:
  - **file / dir evict とも成功**（実体化 → バッジ点灯 →「ダウンロードを削除」→ dataless 化 +
    バッジ消灯の badge-only 配信 = **追加コールバック不要が実機確定**・消灯は既存の
    `materializedItemsDidChange` 経路）。evict 後の再取得（S3 から再 materialize・sha 一致）も確認。
  - **除外温存の安全確認（最重要・レビュー指摘 1）パス = dir の `.allowsEvicting` 維持で確定**:
    `.env`（`ExcludedFromSync` ローカル温存）+ 仮想フォルダを含む dir を全実体化 → evict →
    **ダエモンはローカルのみ item をスキップ**（`.env` 実体・内容無傷 / 仮想フォルダ残存 /
    同期ファイルのみ dataless 化）。
  - **知見①: ダエモンは evict capability を実体化状態でマスク表示する** —
    `fileproviderctl evaluate` の `Capabilities:` は file = dataless で `e` 非表示・実体化で
    `rwdpfet-----`、dir = 実体化配下 1 つ以上で `e` 表示。宣言は常に効いており表示だけの話。
  - **知見②: Finder のフォルダ右クリックは全実体化時のみ「ダウンロードを削除」を出す**
    （部分実体化では「今すぐダウンロード」のみ = Finder 側の集計判断・Tide のバグではない）。
  - **root 除外を確認**: root 右クリックに「ダウンロードを削除」なし + `Capabilities:
    rw----t-----`（e なし・宣言レベルの証跡）。
  - **#104 epoch 機構の実地初回**: Disable/Enable で bump（remove 成功後の確定）→ 新拡張が
    新 UUID を capture（stale capture なし）→ 旧レジストリ 3 本 epoch mismatch 破棄、の全ログ点
    確認。作り直し**前**には v1 schema 破棄 → live 全件 badge-only 再配信（25 items）= 固着
    バッジの自己治癒も実機確認（アプリ更新 + 再起動のみ・応急処置不要を実証）。
  - 副次: 作り直し前でも badge-only didUpdate で再取り込みされた item は新 capabilities を
    先行反映する（再配信分のみ・全量反映は作り直し必須のまま）。プレビューペイン EBUSY を
    実機再現（①どおり・回避可能）。evict は S3 / マニフェスト非接触（soak-check-fp が
    ベースラインと同一の整合 OK・受け入れ全期間エラーログ 0 件）。#93 相互作用（②）は
    未観察のまま任意扱いで据え置き。

#### ウィザードの状態リセット（Issue #102・2026-08-15）

#97 受け入れで発見した「ウィザード窓が完了後も `@State` を保持し続ける」（done 出っぱなし /
同一セッションの import 誘導が見かけ上無反応 / Finish で閉じても直らない = 3 態同根）の修正。

- **機序（再掲）**: `"setup"` は単一・常駐の `Window` scene で、**ウィンドウを閉じても view と
  `@State`（`step` 等）が生存**し `.onAppear` 再発火にも頼れない。import 消費の `.onChange` は
  フィールド充填のみで `step` を動かさなかった。
- **対処 = 「セッション終端」の 3 点で明示リセット**（`SetupWizardWindow.resetWizard()`）:
  1. **Finish 押下**（`onNext` の `.done` 分岐も対称）= dismiss と同時に新規セッションへ。
  2. **import 誘導の消費**（`pendingImportedSettings` の `.onChange`）= リセット **→** 充填の順。
     着地は **credentials**（bucket/region は事前充填済み）— done 到達後は L7 対策で資格情報
     `@State` が消去済みのため、Issue 対処案の `.bucket` 直行では provisioning が必ず認証エラーに
     なる（設計確定 2026-08-15・ユーザ承認）。ウィザード内「Import settings…」ボタン
     （`applyImported` 直呼び）はリセットしない = credentials 入力途中の値を消さない。
  3. **factoryReset 通知** = `AppEnvironment.setupWizardResetVersion`（専用カウンタ・
     factoryReset の実行パスで bump）を `.onChange` で受け,**窓を閉じて**状態破棄
     （設計確定: リセット済みアプリに旧セッションを見せない・Settings 窓が reset 成功時に
     閉じる仕様と対称）。常駐 scene のため窓が閉じていても発火するが dismiss は no-op で無害。
- **世代ガード** = `wizardGeneration`（`probeGeneration` と同パターン）: 世代は**ボタン押下
  tick で capture して async 本体へ引数で渡す**（PR #108 レビュー指摘 = stale「意図」対策。
  `Task { … }` のスケジュールと本体実行の間の 1 tick にリセットが割り込むと、本体側 capture
  ではリセット後の世代を掴んで新セッション上で実行される。`pendingCreateBucket` での判別は
  不可 — alert は正常経路でもボタン押下で isPresented が false に戻るため）。本体は冒頭 +
  await 復帰後の `@State` 書込（log append / `step` / `errorMessage` / `pendingCreateBucket`）
  前に自世代を検査（`onNext` / `runProvisioning` / `runCreateBucketAndProvision` /
  `finishProvisioning` / `runStartSyncing`）。`isWorking = false` の defer も自世代限定 —
  stale 完了の defer が新セッションの実行中フラグを落とすと進行中の新アクションのボタンが
  誤再活性化するため。probe 系は setupGate の外で走るので「進行中に factoryReset /
  import 消費でリセット」は実際に起こり得る。
  `resetWizard` は `probeGeneration` も進めて fileProvider ステップの 10 秒フォールバックの
  遅延書込も無効化する。

##### 実機受け入れ（2026-08-15・全 6 項目パス）

- **3 現象すべて解消**: Finish リセット（同一バケット再セットアップ → done → Finish →
  開き直しで credentials）/ import 誘導（done 窓 → Settings import → 前面 + credentials 着地・
  bucket/region 充填・payload 消費済み）/ factoryReset 連動（done 窓が閉じる → 開き直しで
  credentials）。リグレッション = 通常セットアップ（factoryReset 後フル 2 回）・ウィザード内
  Import ボタンの入力温存、いずれもパス。
- **世代ガードの実機実証**: `/etc/hosts` 黒穴（S3 ホストを 10.255.255.1 へ → HeadBucket が
  接続タイムアウトまでハング）で provisioning 進行中に factoryReset → **ハング中でも両窓
  クローズ** → 黒穴解除後 90 秒静止（stale 完了は成功側で復帰し無ログで破棄 = 成功側ガードの
  想定どおり。失敗側で戻れば `HeadBucket failed` が 1 行残る）。#104 epoch bump の連鎖発火も
  ログで確認。
- **副次知見**: factoryReset の旧世代ロケーション掃除（`LegacyStateMigrator` 系パスの削除）で
  macOS の**アプリデータ分離 TCC プロンプトが初回発火**し、応答まで factoryReset が停止する
  （許可は永続・2 回目以降は非再発。#102 無関係の既存挙動）。受け入れ中に aws CLI セッション
  失効で soak 観測が一時停止（#94 の既知パターン・`aws login` 再認証で復旧・整合 OK
  5625/5625 維持）。

#### FP 拡張トグル OFF の検出（Issue #103・2026-08-15）

システム設定（ログイン項目と機能拡張）で FP 拡張をユーザが OFF にすると、拡張は kill され
レプリカも Finder から消えるのに、アプリは緑表示のまま「無音の同期停止」になっていた問題の
恒久対処。#82（PR #88）受け入れ時（2026-07-25）は機能していた検出が現 OS で不成立になっていた。

- **検出シグナル = `NSFileProviderDomain.userEnabled`（スパイク実機実証 2026-08-15・Issue
  コメント記録）**: トグル OFF では **`domains()` に載ったまま** `userEnabled` だけが false に
  なる（反映 ≤15 秒・ON 復帰も即時。`isDisconnected` / `isHidden` は不変）。SDK ドキュメントに
  「macOS のシステム設定でユーザが無効化すると NO になる」と明記された、まさにこの用途の
  プロパティ。#82 の検出（`domains()` の**掲載有無**のみ）はこの状態を「有効」と誤判定していた。
- **API = `FileProviderController.domainStatus()`**（旧 `isEnabled()` を置換・有界化は同じ）:
  `enabled` / `.userDisabled` / `.notRegistered` / nil（取得失敗）。呼び出し側は
  `== .enabled`（signaler / performSignal）・`!= .notRegistered`（probeDomainRecreation =
  作り直し判定に要るのは登録有無で、userDisabled のドメインもレプリカ実在として扱う）のように
  **明示的に倒す側を選ぶ**（旧 isEnabled と同じ流儀・PR #100 再レビュー指摘 1）。
- **定期検知は #82 の既存骨格を再利用**: `RemoteChangeSignaler.observeFPDomainEnabled`
  （毎周回 + wake + networkUp・HEAD より先 = オフラインでも検出）→ `fpDomainDisabled` →
  `MenuBarPresentation.fpOnlyHeadline` → メニューバーアイコン `MenuBarError`、の配線は
  無変更で、**判定クロージャの差し替えだけで復活**。復帰エッジの catch-up signal も従来どおり。
- **OS 通知（5 事象目・設計確定 2026-08-15）**: signaler に `onFPDomainDisabledEdge` フックを
  追加し、無効エッジで `NotificationEvent.fileProviderDisabled` を発火・復帰エッジで配達済みを
  撤去（`NotificationManager.removeDelivered`）。エッジ検出のみ = 連発しない（回帰は
  `testFPDomainDisabledEdgeHookFiresOnEdgesOnly`）。identifier 固定 `"fpDisabled"`。
  **撤去はエッジ経路だけでは足りない（受け入れ 2026-08-16 で発見）**: 復帰がウィザード
  （completeSetup）経由だと signaler が作り直され、無効状態を保持していた旧 signaler の
  復帰エッジが発火しない（アプリ再起動をまたいだ復帰も同様）。このため
  `launchFPOnlySignalerFromCurrentConfig` は **enabled で立ち上がるとき常に配達済みを掃除**する
  （冪等・不在なら no-op）。
- **UI（設計確定 2026-08-15 = 専用文言 + システム設定誘導）**: ポップオーバー / Settings は
  `DomainStatus?` を保持し、`.userDisabled` で専用赤文言 +「システム設定を開く」ボタン
  （`openLoginItemsAndExtensionsSettings()` = `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`・
  アプリ内 Settings では直せないため）。`.notRegistered` は従来文言。「Open Tide in Finder」の
  disable 条件は両不活性状態（userDisabled はレプリカ不可視）・不明（nil）は従来どおり活性。
- **ウィザードゲート（現象 1・設計確定 = エラーで止める）**: 拡張 OFF でも `add(domain)` は
  **成功してしまう**（#97 受け入れ実測）ため、`runStartSyncing` の completeSetup 成功後に
  `domainStatus()` を検査し、`.userDisabled` なら done へ進めずエラー + 誘導ボタン。設定・
  ドメインは保存済みなので ON にして再度「Start syncing」で冪等に成功（資格情報も温存）。

##### 実機受け入れ（2026-08-16・全 8 項目パス）

- **定期検知**: トグル OFF → poll 周回でエッジ検出 1 回のみ（ログ・連発なし）・メニューバー
  アイコン異常化 + 通知 1 回。**起動時（startup）経路の検知**も副次確認（受け入れ中の
  Cmd+Q 中断 → 再起動で即検出・通知は新プロセスで再発火 = セッション単位のエッジ検出どおり）。
- **OFF 中 UI**: ポップオーバー赤ヘッダ + 専用文言 + ボタンで「ログイン項目と機能拡張」
  ペインが開く・「Open Tide in Finder」disabled（ポップオーバー / Settings 両方）・Settings は
  userDisabled 専用文言（notRegistered と区別）。
- **ウィザードゲート**: OFF で Start syncing → エラー + 誘導で停止（2 回確認）→ ON 後の
  再押下で done 到達（冪等・資格情報温存）。
- **復帰**: アイコン / ポップオーバー復帰。**受け入れが実バグを発見** = ウィザード経由復帰では
  signaler 作り直しで復帰エッジ不発 → 通知撤去が呼ばれず「Tide is not syncing」が通知センターに
  残存 → enabled 起動時の掃除で修正（上記追記・修正ビルドの再起動で通知消滅を実機確認）。
- **正常系**: 書込スモーク往復（作成 / 削除とも `FPEventLog` で S3 反映確認）・`soak-check-fp`
  整合 OK（5625/5625）・言語 = ja（システム日本語での全観察 = 新規文言の ja 表示確認を兼ねる）。
- **副次知見**: メニューバーアイコンの通常（なめらかな波）と異常（ギザギザ波）の差は 18px
  実寸では気づきにくい（受け入れ中のユーザ指摘）。検出機構（本 Issue）のスコープ外 —
  差別化の改善（色 / 記号バッジ等）が要るなら別 Issue。

### バースト RMW 競合の恒久対処（Issue #91・2026-07-26）

#83 受け入れで実測した「100 件バーストで index.json CAS が枯渇 → 部分完了
（孤児オブジェクト + stale index 宣言）」の恒久対処。3 層で潰す（方針 = ②+③+① 複合・
2026-07-26 ユーザ確定）:

- **① リトライポリシー化**（`ConditionalRetryPolicy`）: 旧「100–500ms 一様ランダム × 5 回
  固定・shard/index 共用」を、指数バックオフ（×2 逓増・上限刈り）+ ±25% ジッタへ変更し
  shard 用（5 回・上限 1.6s）/ index 用（8 回・上限 2s）に分離。`ConditionalRetry.run` に
  共通化（**SyncError 素通し・412/409 のみ再試行の規約は不変**）。`ManifestUpdater` は
  両ポリシーを注入可能（既定 = 実運用値・テストは遅延ゼロ注入で枯渇分岐を高速に固定）。
  仕様表は `docs/02`「リトライポリシー」。
- **② index 更新のプロセス内コアレス**（`IndexUpdateCoalescer` actor・本丸）:
  `ManifestUpdater.updateIndex` を全経路コアレッサ経由にし、flush の in-flight 中に届いた
  transform を次の flush へ束ねて「1 回の getIndex → 全 transform 適用 → putIndex(CAS)」に
  畳む。プロセス内の CAS 競合は構造的に消え、リトライが受けるのはプロセス間 / デバイス間の
  残余のみ。**意味論は不変（load-bearing）**: 呼び出し側は自分の transform を含む putIndex の
  確定を await してから戻る =「shard + index 双方確定時のみ発火」の確定点維持・CAS 中止
  （false）の per-caller 返値維持・枯渇はバッチ全員へ伝播。コアレッサは ManifestUpdater
  1 個につき 1 個（struct コピーは同一 actor 共有）。
- **③ 部分完了の孤児根絶**（`SyncError.indexUpdateFailedAfterCommit` + `.removedIndexStale`
  系 outcome）: シャード書込（putShard / deleteShard）**確定後**の index 反映失敗を
  `commitShardWrite` が専用エラーに包み、削除系 RMW（`removeFileEntry` / `removeFileEntries` /
  `moveFileEntries` remove フェーズ）は throw ではなく outcome（`.removedIndexStale` /
  `.movedIndexStale`・除去**確定済み**パスを運ぶ）で返す。FP 拡張はこの outcome でのみ
  **delete marker を発行**（= マニフェスト真実と整合・#83 の削除側 44 件の孤児クラスを根絶）
  した上で**エラー返却は維持**し、fileproviderd の再試行（`.alreadyGone` 収束時の
  `repairIndexDeclarationIfStale` / dangling 除去）に stale index の治癒を委ねる
  （2026-07-26 ユーザ確定 = 治癒ドライバを殺さない側）。**marker 発行は「シャード確定済み」の
  場合のみ** — 未確定の失敗で発行すると「マニフェストが宣言する live オブジェクトへの
  marker」= 不整合になるため、区別はエラー型で構造的に強制する。バッチ削除は index 失敗
  シャードで中断（後続へ進んでも無駄打ち）・move の add フェーズ失敗は従来どおり throw
  （add は孤児を作らない・冪等再入で自己回復）。
- **回帰**: `ConditionalRetryPolicyTests`（遅延帯域）・`IndexUpdateCoalescerTests`（畳み込み /
  per-caller CAS 中止 / バッチ枯渇伝播 / 並行バースト 20 件全数成功）・`ManifestUpdaterTests`
  の #91 節（`.removedIndexStale` 各経路 + 再試行治癒の収束）。
- 既知の残余（変更なし）: stale index の治癒は依然「次の同シャード書込 or 同一操作の再試行」
  駆動（受動型）。②③ で発生源自体が細るため、能動的自己治癒（案④）は発生頻度を見て判断
  （`docs/09` #91 節）。
- **挙動差の記録（PR #92 レビュー観測・いずれも変更不要と判断）**: ① 枯渇時の最悪遅延は
  単発 deleteItem で ≈ 10.8s + 往復（数字の内訳 = `docs/02`「リトライポリシー」。枯渇 =
  エラー返却で fileproviderd が引き取る経路なので実害なし）。② コアレッサ待ちの呼び出しは
  **タスクキャンセルで中断しない**（checked continuation 待ち・drain は独立 Task）: Progress
  キャンセル後も当該 flush の完走まで戻らない。旧実装はキャンセルで `Task.sleep` が即抜けし
  速く失敗していたが、index 書込を中途で見捨てない現挙動の方が確定点不変条件に沿う
  （意図した側への変化）。③ transform が false を返す no-op 呼び出しも同バッチ枯渇時は
  連帯してエラーを受ける（保守的側・再試行の突合修復が拾う）。

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
- **残存レース / orphan version（data loss でない・versioning backstop）**: 本体 PUT が判定の前に走るため、`.conflict`／`.alreadyUpToDate` のどちらでも自分の PUT 版が未参照 orphan として残る（`.alreadyUpToDate` は内容同一で無害）。DB 失敗フォールスルー（行除去失敗→generic backoff）ではリトライのたびに再 PUT＝orphan が増える。読みは全て manifest の versionId 経由なので配信されず、ライフサイクル失効で回収される（事前 GET ＋ TOCTOU を避けるトレードオフ）。2 台同時 `.conflict` で互いのコピーができ得る（稀・自己収束）。

### リモート削除の取り扱い
- **「リモートで消えたファイルをローカル削除するのは、ローカルファイルの SHA が DB 記録（最後にアップロードした内容）と一致するときのみ」**（= `ThreeWayMerge` の `.deleteLocal`）。一致しなければユーザが触っているとみなし（`.keepLocalRemoteDeleted`）、`sync_log` に warning を残してスキップ。`Downloader.applyRemoteDeletion`。
- **空 dir 殻の掃除（Issue #67・2026-07-18）**: `.deleteLocal` の実削除 + DB Tx 成功後に `removeEmptyAncestors(ofDeleted:)` を best-effort で呼び、削除 path の**祖先のみ**を浅い方向へ `rmdir(2)` で掃除する（マニフェストはファイルのみ管理のため、FP 側 dir move の伝播 = 「移動元全ファイル削除 + 移動先全追加」で移動元の殻が残っていた）。設計の要点: ① `rmdir(2)` は空でなければ ENOTEMPTY で失敗する＝「空確認 → 削除」の 2 段を排して TOCTOU を構造的に塞ぐ（**`FileManager.removeItem` は再帰削除のため使用禁止**）。**rmdir 先行**（PR #72 レビュー指摘 1）: 列挙 + `.DS_Store` 単独判定は ENOTEMPTY のときだけ＝非空 dir の打ち切りが syscall 1 回で済み、大きな dir move（同一 dir 内 N 連続削除）で列挙が O(N²) になるのを避ける。② 対象は削除 path の祖先だけ＝ユーザが別所に作った空 dir には到達せず、兄弟に何か残っていれば打ち切り。③ 中身が `.DS_Store` 1 件のみ（lstat 相当で regular file 確認）は unlink → 再 rmdir（ユーザ確定 2026-07-18。Finder が dir を閲覧しただけで置くメタデータで、残すと殻が再残置され続ける。unlink と再 rmdir の間に新規ファイルが出現すると「`.DS_Store` だけ消えて dir は残る」が、`.DS_Store` は Finder が閲覧時に再生成する無害メタデータのため許容 — 同レビュー指摘 2 の記録）。④ 祖先ごとに `PathValidator.resolveForWrite`（祖先 symlink 脱出拒否）+ dir 自体の symlink 停止・`.tide` 対象外・syncRoot 自体には不達。⑤ `.keepLocalRemoteDeleted` / ローカル不在（孤児 record 掃除）経路では呼ばない。FP 拡張側は fileproviderd が dir を管理するため対象外。回帰は `RemoteDeletionTests` の掃除節（11 件・`.DS_Store` 単独祖先への連鎖 = rmdir 先行の ENOTEMPTY 分岐複合を含む）。
- **event `.deleted` の採用未了ウィンドウ（Issue #69・2026-07-18）**: record 不在の削除イベントは原則 no-op（未追跡＝同期対象外）だが、factoryReset → 再セットアップ直後の「マニフェスト掲載済み・DB 採用前」の窓では削除の黙殺になる。対処は 2 点セット — ① event 側: `SyncEngine.shouldPropagateDeletion`（nonisolated static）が「未追跡 ∧ リモート既知 ∧ ignore 非該当」で delete を enqueue する。リモート既知は直近 pull の `remoteKnownPaths`（in-memory・**シャード単位マージ** = 変化/削除シャード分だけ差し替え・無変化シャード分は前回値を温存。`ManifestReader` は無変化シャードを FileRecord から再合成するため、丸ごと差し替えると 2 回目以降の pull で未採用 path が脱落し窓が再び開く）。② pull 側: `reconcileRemoteEntry` の `.download` 分岐で「record 無し × ローカル不在 × 同 path の delete 行 pending」（`hasPendingDelete`・読み取りのみ）は取得しない＝event 側 enqueue と in-flight pull の逆転レース（復活 → 片肺 delete）を閉じる。**この判定を scan へ展開してはならない** — 「リモート既知だが record も実ファイルも無い」を scan で delete に倒すと、クリーンインストール復旧中の未ダウンロードファイル全部に delete を打つ（FSEvents `.deleted` イベント＝ローカルに実在した削除の証跡、に限定するのが load-bearing）。ignore ガードは「他デバイス由来でマニフェストに載る ignore 被マッチ entry」の片方向破壊防止。既知の残余（初回 read() 完了前の数秒窓・採用途中の再起動後 = `remoteKnownPaths` 非永続・**dir 単位の削除** = Finder ゴミ箱行きは dir rename で子のイベントが出ず〈docs/04 既知〉、dir path の `.deleted` しか届かないがマニフェストに dir entry が無いため黙殺継続 — scan 展開禁止の下では原理的に対処不能・PR #71 レビュー観察 2）は「一度復活 → 再削除で収束」（#68 残余と同型・versioning 90 日で可逆）。ただし **dir 単位の再削除（Finder ゴミ箱）だけは復活後も event で拾えない**（復活で子ファイルは追跡済みになるが dir rename は子イベントを出さない）ため、正確には「再削除 + **次回フルスキャン**（起動時 / 手動同期 / restore 成功後 / `.syncignore` 変更時。poll/wake/network は scan を走らせない）で収束」。`rm -rf` なら子ごとにイベントが出て event 経路で即収束（追跡済み dir 削除の従来挙動と同一・PR #71 再レビュー精度補足）。回帰は `ScanEventWiringTests`（`shouldPropagateDeletion` 真理値表 + `mergedRemoteKnownPaths` マージ規則 3 点 = 無変化温存 / 変化差し替え / removed 脱落）と `ReconcileWiringTests`（pull 側ガード 3 件）。

### `.syncignore` 除外ルール（M3）
- **構文は gitignore の一般的サブセット**: `*` `**` `?`、先頭 `/` アンカー、末尾 `/` でディレクトリ限定、`!` 否定（再包含）、`#` コメント、空行。`SyncIgnoreMatcher` がグロブを**トークン列**に変換し、照合は **reachable-set DP**（`O(パターン長 × パス長)`）で行う（**ユーザ正規表現は受けない**）。サイズ上限 256 KB / パターン数上限 10,000。
- **ReDoS は構造的に解消済み（F1 / L8、2026-06-04）**: 旧来は生成正規表現を `NSRegularExpression`（ICU = バックトラッキング）で照合していたため `*a*a*…` 系で破滅的バックトラッキングが起こり得たが、`NSRegularExpression` を廃して線形時間照合（トークン列 + reachable-set DP、バックトラッキング無し）に置換した。`parse` の上限（`maxPatternLength` / `maxWildcardsPerPattern` / `maxMatchPathLength`）は ReDoS 防御の load-bearing ではなくなったが、**防御的サニティ上限として保持**（資源消費の有界化）。意味論は旧 regex 実装との differential fuzz（`SyncIgnoreMatcherTests.testLinearMatcherMatchesReferenceRegex`）で同値を担保。
- **ハードコード除外（機密網）は常に最優先**。`.syncignore` の否定 `!` では `.env` 等を再包含できない。「既存は触らない」緩和は**ユーザパターンにのみ**適用し、ハードコード除外には適用しない。
- **gitignore 純正（既存は触らない）**: `.syncignore` のユーザパターンは**新規ファイル（未追跡 = `FileRecord.lastSyncedAt == nil`）にのみ**適用。既に同期済みのファイルは同期継続、S3 からも自動削除しない。バックアップから外したい時はローカル削除 → 通常の削除伝播。
- **`.syncignore` 自身は同期対象に含める**（S3 経由で全デバイス・復旧後にも伝播）。`IgnoreDecision.shouldSkip` は `.syncignore` 自身（ルート/ネスト両方＝末尾 `/.syncignore`）を決して除外しない。判定は共有ヘルパ `IgnoreDecision.isSyncignoreFile` に一本化（自己保護と変更検知の両方で使う）。
- スキップ判定は純粋関数 **`IgnoreDecision.shouldSkip(relativePath:isAlreadyTracked:matcher:)`** に集約し、`performFullScan`（走査本体は `walkSyncTree` / `classifyAndEnqueue`）/ `processEventToQueue` / `reconcileRemoteEntry` の 3 経路すべてで通す。`.syncignore` の読込は `PathValidator.resolveSafely` 経由 + symlink 非追従（共通実装は `readSyncignoreLayer`）。`.syncignore` 変更は FSEvents で拾い、変更された 1 枚のインプレース patch（`patchIgnoreLayer`・#64）+ フルスキャン再評価（層辞書の全体再構築は scan の走査副産物）。
- **ネスト `.syncignore`（git 風の階層オーバーライド・[#27] / C1・2026-06-25）**: ディレクトリごとの `.syncignore` を階層適用する。`SyncIgnoreMatcher.evaluate` を三状態（`unmatched`/`ignored`/`included`）化し、新 `LayeredSyncIgnore`（`[dir 相対パス: SyncIgnoreMatcher]` を束ねる `Sendable` 値型）が層合成を担う。対象パスの祖先ディレクトリの `.syncignore` を**浅い→深い順**に評価し、各層には「その層のディレクトリからの相対パス」を渡す（深い層が浅い層を上書き＝last-match-wins を階層へ拡張・マッチ無しの層は上位の判定を維持）。`IgnoreDecision.shouldSkip` の `matcher` 引数は `LayeredSyncIgnore`。
  - **キャッシュ戦略**（2026-06-25 確定「変更時フル再構築」→ #64・2026-07-21 で更新）: in-memory の dir→matcher 辞書がキャッシュ本体で、**評価のホットパス（scan/event/reconcile の 3 経路）は I/O ゼロ**（祖先 dir を辞書引きするだけ）。辞書の再構築は — **起動時・ローカル `.syncignore` 変更時はフルスキャンの走査副産物**（walk フェーズ = `walkSyncTree` が組み上げ、分類フェーズを待たず**フェーズ間で publish**・先行 discovery 走査なし＝ツリー走査 1 回）、ローカル変更時はさらに**変更された 1 枚のインプレース patch**（`patchIgnoreLayer`・走査ゼロ）を scan 前に同期適用、リモート由来は **pull が `.syncignore` を触ったときだけ** `reloadIgnoreMatcher()`（`performRemotePull` で「shard 変化 ∧ path が `.syncignore`」を過大近似検出・取りこぼし防止＝`loadLayeredIgnore` の discovery 走査はこの経路専用に残置）。**定常 pull / 通常ファイル編集ではツリーを再走査しない**。詳細は下記「フルスキャンの単一走査化」節。
  - **走査の安全境界**: `loadLayeredIgnore` のツリー走査は symlink を絶対に追従せず（symlink item は `continue` のみ。deep enumeration は symlink へそもそも再帰しないため十分で、**symlink item での `skipDescendants()` は無関係な隣接ディレクトリを走査から脱落させるため呼ばない** — Issue #54・2026-07-05 修正）、機密網ディレクトリ（`HardcodedIgnoreRules`、`.tide`/`.aws` 等）は丸ごとスキップ（こちらは「現在 item がディレクトリ」の文脈での正しい `skipDescendants` 使用）、各 `.syncignore` は `PathValidator.resolveSafely` + symlink 再確認 + 256KB 上限。読み込む `.syncignore` 数は `LayeredSyncIgnore.maxFiles`(1000) で防御的に有界化（超過分は「除外しない＝同期する」安全側）。scan 側（`walkSyncTree`・再帰下降）の同等の境界は下記「フルスキャンの単一走査化」節。
  - **Settings 表示**: `LayeredSyncIgnore.directoryGroups`（ディレクトリ深さ昇順）でディレクトリ単位にグルーピング表示。`activeIgnorePatterns` の型も `[LayeredSyncIgnore.DirectoryGroup]` へ変更。
  - **据え置き**: 親ディレクトリが除外された配下のファイルを `!` で再包含する gitignore 挙動は本対応でも厳密には再現しない（同一/別階層の否定は正しく動く）。
- **既定テンプレートの自動生成**: `AppEnvironment.completeSetup` で、**ローカルに `.syncignore` が無く、かつリモートにマニフェスト（`getIndex()`）も無い「新規バケット」のときだけ** `SyncIgnoreMatcher.defaultTemplate`（`node_modules/` 等の再生成可能な開発ジャンク）を `<syncRoot>/.syncignore` に書き出す。**既存バケットに参加する場合は作らない**（他デバイスの `.syncignore` と競合してコンフリクトコピーが散らかるのを防ぐ）。`HardcodedIgnoreRules` とは別物（ユーザが編集・削除でき、`!` で上書きも可能）。`.git/` は復旧目的のためテンプレートに含めない＝同期対象のまま。

### フルスキャンの単一走査化と `.syncignore` 層辞書の走査副産物化（[#64]・2026-07-21）

起動時とローカル `.syncignore` 保存時に discovery 走査（`loadLayeredIgnore`）→ scan 走査（`performFullScan`）と
**同じツリーを 2 回フル走査**していた問題（PR #39 レビュー指摘・docs/09）の解消。flat な `FileManager.enumerator`
は子の列挙順が不定で「dir の `.syncignore` を配下ファイル評価より先に読む」を保証できない（鶏卵）ため、
走査本体を**ディレクトリ再帰下降**へ書き換えた。

- **走査本体は 2 フェーズ**（`Tide/Core/SyncEngine+FullScan.swift`・いずれも `nonisolated static` +
  依存注入＝直接駆動テスト可能。PR #74 レビュー中 3 で分割）:
  1. **`walkSyncTree(root:)`** — FS 走査のみ（stat + 層辞書 + 対象ファイル収集・**DB 非接触**）。
     明示スタックの反復 DFS（深いツリーでコールスタックを消費しない）で、各 dir **進入時にその dir の
     `.syncignore` を読んで層辞書へ加える**（git モデル）。
  2. **`classifyAndEnqueue(walk:db:now:)`** — 収集済みリストへ per-file の DB read → `shouldSkip`
     （未追跡のみ・完成済み層辞書で評価。`evaluate` は祖先層しか見ないため走査時の部分文脈評価と同値）→
     foundPaths 簿記 → `classifyLocalChange` → 削除先行の 2 段 enqueue。パイプラインの内容・順序は
     旧 flat 実装と同一。
  `performFullScan` は両フェーズを `Task.detached(.utility)` で包む薄い @MainActor 殻（合成 API
  `singlePassScan` はテスト用の便宜）。
- **走査副産物の publish はフェーズ間**: 層辞書は walk フェーズ完了時点で完成するので、分類フェーズ
  （per-file DB read / 変更時 hash＝大きなツリーでは分オーダー）を**待たずに** `ignoreMatcher` /
  `activeIgnorePatterns`（Settings 表示）へ publish する。起動時・`.syncignore` 保存時の先行
  `reloadIgnoreMatcher()` は撤去（`start()` は `triggerFullScan()` 直行）＝**ツリー走査が 1 回**になり、
  起動時に「matcher 空のまま event が評価される窓」も旧 discovery 走査相当の長さのまま拡大しない
  （scan 完了まで publish を遅らせると、起動直後のビルド生成物 event が空 matcher で upload → 除外が
  未追跡限定のため恒久追跡化し得た。PR #74 レビュー中 3）。
- **世代ガード（`ignoreGeneration`）**: publish は「走査 / リロード開始時点から matcher 世代が進んで
  いない」ときだけ行う（`publishRebuiltIgnoreMatcher` → Bool 返し）。走査中にイベント patch が挟まった
  場合、走査の副産物は stale として捨てる — patch 側は `triggerFullScan` を coalesce（`pendingFullScan`）
  しているので続く scan が新世代の完全な辞書を publish する。**pull 末尾の `reloadIgnoreMatcher` も同じ
  ガードを通し**、stale なら publish せず `triggerFullScan()` へフォールバックする（無条件 publish だと
  「reload の walk が dir X を読む → patch が X の新層を publish → reload が古い X を publish → 訂正 scan の
  副産物は世代不一致で捨てられる」の順序で stale 層が自己修復せず残留し得た。PR #74 レビュー低 4）。
- **event 経路 = 変更 1 枚のインプレース patch（`patchIgnoreLayer`）**: FSEvents は変更された `.syncignore` の
  path を知っているので、その 1 枚だけを安全読込（`readSyncignoreLayer`・走査と共通実装）して
  `LayeredSyncIgnore.updatingLayer` で層差し替えし即 publish する
  （**ツリー走査ゼロで「保存直後〜scan 完了までの後続イベントが旧 matcher で評価される窓」を閉じる**。
  窓を許容すると、ビルド実行中に `build/` を `.syncignore` へ追記したケースで窓中の生成物イベントが upload →
  追跡化され、除外が未追跡限定のため恒久同期化する事故があり得た）。消滅 / 読込不能 / 空パターンは層の除去。
  機密網配下はゲートで no-op。新規層の追加が `maxFiles` を超える場合は patch を見送る（既存層の更新/除去は通す）。
- **`readSyncignoreLayer` の安全ゲート（走査 / patch 共通）**: `PathValidator.resolveSafely`（root エスケープ
  拒否）+ **lstat 相当（`attributesOfItem`・symlink 非追従）の regular file 確認** + 256KB 上限。regular file
  確認は symlink に加えて **FIFO / socket を open 前に拒否**する — FIFO を `Data(contentsOf:)` すると書き手
  待ちで永久ブロックし、detached の走査タスクが返らず `isFullScanning` が解放されないため**以後の全スキャンが
  再起動まで停止**する（旧 `loadLayeredIgnore` の `isRegularFile` ガード相当。共通実装の初版で欠落した回帰を
  PR #74 レビュー高 1 で修正）。**空パターン（コメントのみ）は nil = 層なしへ正規化**（patch の「新規層の追加」
  `maxFiles` ガードが除去相当の patch を誤スキップしない。全再構築でも空層は init が落とすため意味論同値。同 nit 5）。
- **旧 flat 実装との意図的な挙動差**: ① 機密網 dir は subtree ごと**降りない**（旧実装は降りて per-file
  フィルタ。`HardcodedIgnoreRules.shouldIgnore` はコンポーネント単位判定なので検出結果は同値・stat が減るだけ）。
  ② **列挙失敗の扱い**（PR #74 レビュー高 2）: **syncRoot 自体**が列挙不能ならスキャン全体を中断
  （旧 enumerator は黙って空を返し、foundPaths 空のまま削除検出へ進んで**全ファイル誤 delete** し得た）。
  **配下 dir** の列挙失敗はその subtree だけ skip して走査を続行し、**削除検出のみ抑止**（`scanIncomplete`）+
  `recordIssue`（`.localIO`）で可視化 — 旧実装の「黙って skip → skip された subtree の追跡ファイルが誤 delete」
  も、「読めない dir が 1 個あるだけで upload / 層辞書 publish まで全滅（＝`.syncignore` 除外が event 経路で
  恒久無効化）」も避ける。③ `.syncignore` が `maxFiles` 超過でも**走査は最後まで続ける**（層の追加だけ
  打ち切り。旧 discovery は走査ごと break だったが、scan は削除検出の正しさのため全域走査が必須）。
- **symlink 非追従（C2 / Issue #54）**: 再帰下降では symlink（dir リンク含む）を**スタックへ push しない**＝
  構造的に降りない。他の子の走査へ影響する API（`skipDescendants()`）自体を使わないため、Issue #54 型の
  誤用は起こり得ない。終端不変条件（全ファイルが走査に載る・dir-symlink に降りない）は既存
  `FullScanSymlinkTests` が引き続き固定（`loadLayeredIgnore` は enumerator 残置なので同スイートの
  列挙順前提アサートもそちらで生きる）。
- **テスト**: `FullScanSinglePassTests`（走査本体の直接駆動: 同一走査内の層適用・深い層の上書き・層辞書副産物・
  機密網 subtree 非降下・maxFiles 打ち切り後の走査継続・列挙失敗の fail-safe〈root 中断 / 配下 skip + 削除抑止〉・
  FIFO ゲート・空パターン正規化・walk フェーズ単体の辞書完成）/ `SyncEngineIgnorePatchTests`
  （patch の追加/更新/除去・symlink/FIFO/機密網ゲート・世代ガードの返値と巻き戻し防止）/
  `SyncIgnoreMatcherTests`（`updatingLayer`）。

### `xcodegen` / Xcode プロジェクト
- **`Tide.xcodeproj/` は git 追跡対象**。`make generate` 後の差分も同じコミットに含めるのがルール。
- xcuserdata は除外。

### `Localizable.xcstrings` の運用
- **新規キーには必ず `extractionState: "manual"`** を付ける（Xcode の自動 purge を防ぐため）。
- **「キーが既に登録されていないか」を編集前に `grep` で確認**（汎用語の重複事故が起きやすい — 過去に `"Region"` 重複で JSON が壊れた）。
- **カタログはターゲットごとに 2 つ**（M5 Phase 4〜）: アプリ向け文言は `Tide/Resources/Localizable.xcstrings`、**File Provider 拡張向け文言は `TideFileProvider/Resources/Localizable.xcstrings`**。appex 内の `String(localized:)` は `Bundle.main` = **拡張バンドル**から解決するため、拡張の user-facing 文言をアプリ側カタログへ足しても効かない（逆も同様）。なお拡張プロセスの言語は**システム言語**に従う（`make run-ja/en` の `-AppleLanguages` はアプリプロセスにしか効かない）。

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
- **pull と restore の単一ゲート統合（[#34] / D5・2026-06-30）**: 旧ゲートは `isRemotePulling` の bool 1 個で **pull 同士**しか排他しておらず、**復元（`RestoreService.restore` の atomic move）と並行 pull の reconcile / 削除反映が同一 path に同時に触れる窓**が残っていた（手動操作 + フルスキャン委譲で実害報告は無かったが安全側に寄せる）。bool を `RemoteOpGate`（`@MainActor` の非再入 async ロック・`Tide/Core/RemoteOpGate.swift`）へ一般化し、pull と restore を **1 本のゲートで排他**する。`@MainActor` 隔離なので `tryAcquire` / `release` は同期＝旧 bool と同じ check→set の原子性を保つ。**pull は `tryAcquire`**（busy ならドロップ、手動だけ pending・従来挙動を維持）、**restore は `acquire`**（保持中なら FIFO 待機）。restore は in-flight pull / 先行 restore の完了を待ってから書き戻すので move と reconcile が同一 path に同時に触れない。restore 同士も直列化され、同一 path+versionId の `restore-<hash>.part` 衝突も消える。`SyncEngine.restore` は `acquire → service.restore（重い DL〜move は off-main）→ release` の順で、**`triggerFullScan` はゲート外**で回す（ローカル走査＝enqueue のみで FS 競合無し、ゲート保持を最小化）。**復元中の手動 Pull の pending は restore の成功/失敗どちらの経路でも対称に 1 周 drain**（`drainPendingManualPull`・pull 経路の repeat-while-pending が失敗時もセルフ drain するのと対称＝pull 中押下の coalescing を restore 経路へ拡張）。drain は `release()` 直後に呼び、`triggerRemotePull` は `tryAcquire` まで await を挟まないので**先行待機 restore が無ければ**ゲートは空いて取得・実行される。先行待機 restore がいる場合は `release` が所有権をそれへ引き渡す（`locked` は true のまま）ため tryAcquire は失敗して再 pending 化されるが、所有権を受け取った restore が完了時に再度 drain するので取りこぼしは無い。`isRemotePulling` は **UI 表示専用**（pull 中のみ true）に残し、「Pull from S3」ボタンのスピナー表示は不変。テストは `RemoteOpGateTests`（tryAcquire 排他・acquire 待機→解放で復帰・並行 acquire の同時保持≦1 と全完走＝lost wakeup 無し）。`acquire` 待機中の Task キャンセルは伝播しない（保持側が必ず release＝待機は永久化せず、キャンセルされた呼び元も取得直後に自身でキャンセルを観測して速やかに release）。

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
- **Version History の競合・負荷対策（PR #16 レビュー反映・2026-06-10）**: 削除済みスキャンの再検索/キャンセルは**世代トークン**（`scanGeneration`）で stale 書込を抑止する — `Task.cancel()` は in-flight の `await listObjectVersions` 復帰後の state 書込までは止められないため、各書込前に世代一致を確認して旧タスクを捨てる（`isScanningDeleted = false` も世代一致時のみ）。累積全件の再グルーピングは `Task.detached` で off-main（MainActor 継承 Task 内で直に呼ぶと大規模バケットで UI がカクつく）。`loadVersions` は冒頭 `isLoading` 再入ガード（`onSubmit`/同期一覧の行クリック経由はボタンの disabled を素通りする）。divert（別名退避）復元時は Deleted 一覧から**外さない**（原 key は delete marker のまま＝「現在削除済み」を維持）。（旧 `chooseFile`＝`NSOpenPanel` で選んだファイルを syncRoot 配下か両辺 `resolvingSymlinksInPath()` で突合し相対化していた導線は、下記「同期一覧からのファイル選択（#28）」で撤去済み。）
- **同期一覧からのファイル選択（#28・2026-06-26）**: 「Versions」タブのチューザを、ローカル DB `files` の同期済み相対パスを引く**インライン一覧**に置き換え。`VersionHistoryModel.loadSyncedPaths`（`FileRecord.fetchAll(db).map(\.path)` を `localizedStandardCompare` で自然順ソート・タブ表示時の `.task` で 1 回読込・失敗は非致命で握りつぶし）で取得し、`filteredSyncedPaths`（`pathInput` を `localizedCaseInsensitiveContains` で部分一致・空入力は全件）で**メモリ内絞り込み＝I/O ゼロ**。入力欄 1 本が「絞り込み検索」と「任意パスの手入力（`onSubmit`/Load で `loadVersions` に直接渡す＝DB に無いパスも参照可）」を兼ねる。行クリックは `selectSyncedPath`（`pathInput` をそのパスにして `load()`）。同期一覧でほぼ代替されるため重複していた `NSOpenPanel`（Choose… / 旧 `chooseFile`）と関連 xcstrings（`Relative path …` / `Please choose a file …`）は撤去（`import AppKit` も不要に）。一覧は高さ 150 で版一覧 List と縦に同居、`loadedPath` 行に checkmark。**「Deleted files」タブ（delete marker 列挙）は本変更のスコープ外で不変**。
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

- **発火は「ユーザの介入が要る／取りこぼし（未バックアップ）が起きうる確定的な事象」だけに絞る**（5 種）: ① 競合コピー作成（`reconcileRemoteEntry` の `.conflictThenDownload`）、② サイズ上限超過 `fileTooLarge`、③ リトライ give-up（`attempts >= 5`）、④ 不安定ファイル（`unstableFile` 警告・既に `unstableWarned` で dedup 済み）、⑤ **FP 拡張のユーザ OFF**（`fileProviderDisabled`・fpOnly = 全同期停止・Issue #103・2026-08-15 追加。発火元は SyncEngine ではなく `RemoteChangeSignaler` のエッジ検出 = 連発しない・identifier 固定 `"fpDisabled"`・復帰エッジで配達済みを撤去。詳細は「FP 拡張トグル OFF の検出」節）。**一過性エラー（network 等）は出さない**（オフラインのたびに通知が溢れるのを避ける＝本ファイル「構造化エラー」の `recentIssues` とは別ポリシー: recentIssues は全失敗を載せるが通知は確定事象だけ）。
- **配線は `SyncEngine`（@MainActor）の各点から fire-and-forget の `Task { await self.notifier?.post(...) }`**（PR #18 レビュー Medium）。`post` の初回呼びは許可プロンプト応答までサスペンドし得るため、インライン `await` だと確定エラー 1 件で以降のアップロード処理（特に `fileTooLarge` 分岐はキュー除去 Tx の直前）が宙吊りになる。通知は順序保証不要なので同期処理から切り離す（@MainActor 同士＋ path 値渡しで安全）。
- **判定は純粋関数 `NotificationPolicy.content(for:) -> NotificationContent`（`Tide/Core/NotificationPolicy.swift`）**。`NotificationEvent` enum（上記 5 種）→ `(identifier, title, body)`。**identifier は `"<種別>:<path>"`**（例 `conflict:a/b.txt`。path を持たない `fileProviderDisabled` は固定 `"fpDisabled"`）で、UNUserNotificationCenter の「同一 identifier は置換」仕様により同一 (path, 種別) の連発を 1 件に畳む（バナー溢れ防止）。本文はフルパスでなく**末尾コンポーネント**（通知は幅が狭い）。全分岐 `NotificationPolicyTests`（identifier の安定性 / path・種別での分離 / 本文がファイル名を含む）。表示文言は xcstrings（`%@` 一個・`extractionState:"manual"`）。
- **発行と OS 連携は `NotificationManager`（`Tide/App/NotificationManager.swift`・@MainActor・`SyncNotifying` 実装）**。SyncEngine には `SyncNotifying`（`NotificationPolicy.swift` 定義）だけ注入し、UserNotifications / AppKit を持ち込まない（テストでも nil 差し替え可・既存 SyncEngine 直構築は AppEnvironment 1 箇所のみ）。`AppEnvironment` が 1 インスタンス保持し `notifier:` で SyncEngine へ注入。
- **許可（authorization）は初回 `post` 時に一度だけリクエスト**（起動時・セットアップ時には出さない＝エラー/競合が一度も起きないユーザにいきなりプロンプトしない）。許可されていなければ静かに諦める。Settings の「Notifications」トグル（`ConfigStore.notificationsEnabled`・**既定 on**・presence 判定）が off なら許可も求めない。`factoryReset` で消える設定群にも追加済み。
- **初回リクエストは単一タスク `authorizationRequest: Task<Void, Never>?` に集約**（PR #18 レビュー Low）。並行 post はこのタスクの完了を `await` してから `notificationSettings()` を読むので、初回プロンプト応答待ち中に来た 2 件目が `.notDetermined` で early-return＝取りこぼされない。許可状態は毎回読む（後から System Settings で許可された場合も拾う）。`requestAuthorization` は `.notDetermined` のときだけプロンプトを出し確定済みなら即返る。
- **通知クリックで Sync Activity を開く**: `NotificationManager.openActivity` クロージャを App 層が登録する（`openWindow` は SwiftUI の View 環境にしか無く AppKit デリゲートから直接呼べないため）。登録は **MenuBarExtra のラベル（`MenuBarLabel`・常駐アプリでは起動直後に必ず生成される）の `onAppear`** が一次、`MenuBarContent.task` が保険。クリック時も `openWindow` 前に `NSApp.activate`（LSUIElement の定石）。デリゲート登録は `AppDelegate.applicationDidFinishLaunching` で `registerAsDelegate()`。
- **据え置き**: file 名（末尾コンポーネント）が OS 通知本文＝ロック画面等に出うる（メタデータ露出）。バックアップツールとして「どのファイルか」を伝えるのが通知の目的なので by-design・トグル + OS 許可でゲート・**生エラー文字列は通知に出さない**（`SyncIssue.rawDetail` は通知に載せない）。`security/README.md` に注記。**実機受け入れ消化済み（✅ 2026-06-16・対話形式・チェックリストは運用どおり削除）**: ① 競合バナー（同期済みファイルを `chmod 000` → `.unreadable` → `.conflictThenDownload` で単一マシン再現）、② fileTooLarge バナー（1GiB 超スパースで誘発・FD `fstat` のみで本体未読のまま弾く）、③ バナークリック → Sync Activity 起動、④ トグル off で抑止（許可プロンプトも出ない＝`post` 冒頭ガードが `authorizationRequest` の前で return）、⑤ 初回許可プロンプト（OFF→ON 後の最初の確定事象で 1 回）を実機確認。give-up / unstable バナーは `NotificationPolicyTests` + 同一 `notifier?.post` 経路で担保しライブ確認は省略（divert と同じ判断）。**消化中に `ConflictNamer` のタイムスタンプ書式バグを発見し修正**（→ §3「競合ファイル命名」の注記）。
- **将来の追加候補（PR #18 レビュー・スコープ外メモ）**: `applyRemoteDeletion` の `.keepLocalRemoteDeleted`（リモート削除だがローカル編集で残した＝ユーザ判断が要る）も通知候補。現状 sync_log warning のみで通知はしない。将来の通知拡張時に検討（⑤ は #103 で 2026-08-15 に追加済み）。

### reconcile 入口の stat ゲート（M4 perf・pull コスト削減・2026-06-16）

- **問題**: `SyncEngine.performRemotePull` → `reconcileRemoteEntry` は remoteMap の全 entry を処理するが、未変化シャードの entry は `ManifestReader` が DB レコードそのものから再合成する（sha/etag/versionId/size/mtime 全部 DB 由来）。よって steady-state では「ローカル == DB == リモート」なのに**毎 pull（最短 3 分毎）に全ファイルを 2 回 hash（`ThreeWayMerge` 用 + `download()` 早期 return 用）＋ 全行 DB write**。さらに reconcile は `@MainActor` 上で hash していた（`processEventToQueue` だけ `Task.detached` で逃がしていた）＝pull 中のメインスレッドブロック。
- **修正（3 点）**:
  1. **stat ゲート**: reconcile 入口で純粋関数 **`ChangeDetector.reconcileIsNoop`** を呼ぶ。`preDecision == .skip`（ローカル stat == DB の size/mtime）かつ DB が entry を**そのまま反映**（`DB.sha == entry.sha256 && (DB.s3Etag ?? "") == entry.etag && DB.s3VersionId == entry.s3VersionId`）なら、`markSynced` が書く値と timestamp（`lastSyncedAt`/`updatedAt`）以外完全一致するので**証明可能な no-op**としてスキップ（hash も DB write もしない）。timestamp の bump 省略は無害: 再合成マニフェストの `uploadedAt` に使われるだけで、再合成は read 専用＝S3 に戻らず比較対象にもならない（むしろ「最後にアップロードした時刻」として正しい）。
  2. **`.localMatchesRemote` を `download()` から分離**: ゲートを抜けた `.localMatchesRemote`（= 実際に mtime ドリフト / etag ドリフトの修復が要るケースだけ残る）は専用 **`Downloader.markSynced`**（= 旧 `updateDBEntryWithoutWrite`）へ。`download()` 内の二度目 hash（`currentLocalSha`）を排除。`.download` / `.conflictThenDownload` は従来どおり `download()`（早期 return の安全網は温存）。
  3. **残る hash を off-main 化**: ゲートを抜けて hash が要るケースの `HashCalculator.sha256` を `Task.detached(priority:.utility)` へ（`processEventToQueue` と同パターン）＝pull 中のメインブロック解消。
- **ゲートの厳密さ = 厳密版（no-op 証明可能）を採用**（会話で確定）。クロスデバイスで同一内容が再 UL され etag だけ変わった場合はゲートが外れ、通常経路の hash → `.localMatchesRemote` → `markSynced` で DB の etag/versionId が最新化される（より正しい方向）。**S3 マニフェストは Uploader しか書かない**ので、ゲートで etag/versionId 更新を省いても S3 汚染の経路は無い（再合成は read 専用）。
- **安全性**: ゲートは `preDecision`（既存の SHA ゲートと同じ「size+mtime 一致 → 内容不変とみなす」前提）を流用＝`performFullScan` と同じ accepted な前提を継承し新たな取りこぼし窓を作らない。`localRec.sha256 != entry.sha256`（リモート変化）/ size or mtime ドリフト / 未追跡 のいずれでもゲートは外れ通常経路へ落ちる。`ChangeDetectorTests` の `reconcileIsNoop` 群で全分岐固定（一致 → no-op / sha・etag・versionId 差 / size・mtime 差 / known nil / 未同期 / 空 etag + nil versionId）。配線（判定 → I/O）の結合テストは下記「判定 → 実 I/O 配線の結合テスト」（D1 / #30）で整備済み。
- **実機受け入れ消化済み（✅ 2026-06-16・対話形式・チェックリストは運用どおり削除）**: 観測信号は `files.updated_at`（pull のたびに reconcile が全行 DB write すれば bump される）。**BEFORE**＝変更前ビルド（旧 running app）が、内容無変更のまま poll のたびに全 3 ファイルの updated_at を bump（03:28:48→03:31:49→03:34:51・180s 間隔）し、しかも `.syncignore` の shard は再 fetch されていない（etag キャッシュ）のに updated_at が進む＝再合成 entry でも全行 write する無駄を実機確認。**AFTER**＝新ビルド（PR）に差し替えると、起動 pull・周期 poll を跨いでも updated_at 凍結（ゲート発火＝write 無し・余計な sync_log 無し）。**実変更の往復**＝`perf-b.txt` を編集→新ビルドがアップロード（DB/S3/sha 更新）→ 次 poll で **shard 46 が S3 から再 fetch された**のに perf-b の updated_at は進まず（DB 再合成 entry だけでなく S3 から取り直した生 entry に対してもゲートが正しく no-op 化・再 UL ループ無し）。pull の `.download`/`.conflictThenDownload` 分岐は本 PR で不変（同一 `dl.download()`・`DownloaderTests` + reviewer 解析で担保）なため move-out による live `.download` 検証は不採用（起動時 `performFullScan` の missing→削除キュー投入が pull の再 DL と競合し S3 削除を伝播しうるため）。bucket `dev-tide` / sync root `/Users/hige/Tide` で実施、後始末でテストファイルを削除し S3/DB を元状態へ復元。

### 判定 → 実 I/O 配線の結合テストと nonisolated static 抽出（D1 / #30・2026-06-27）

純粋判定（`ThreeWayMerge.decide` / `ChangeDetector.preDecision`/`postHash`）は全分岐網羅済みだったが、
その判定を実 I/O（download / DB write / enqueue / 削除）へ振り分ける switch マッピングが結合テスト未整備で、
取り違え（データ損失 / 再アップロードストーム / 無エラー乖離）を回帰検出できなかった。Issue #25 / A が導入した
**「`nonisolated static`/struct + 依存注入 + 実 temp DB + フェイク S3（`FakeRangedDownloadClient`）」型**を 4 配線へ横展開した。

- **テスタブル化の分担パターン**: @MainActor 固有の副作用（`notifier.post` の fire-and-forget・`recentIssues` への
  append・`refreshQueueDepth`・`reloadIgnoreMatcher`/`triggerFullScan`）は `@MainActor` の薄いラッパに残し、
  **判定 → I/O の本体を `nonisolated static` へ純粋移設**して注入クロージャ（`postConflictCopy` / `recordIssue`）で
  副作用を配線する（`resolveUploadConflict` / `pruneOrphanTransfers` と同型）。
- **抽出した static（すべて `SyncEngine` 上）**:
  - `reconcileRemoteEntry(path:entry:dl:db:syncRoot:matcher:postConflictCopy:recordIssue:)` — pull 取り込み。
    `performRemotePull` からは 3 引数の `@MainActor` ラッパ経由（無変更）。
  - `classifyLocalChange(existing:fileURL:size:mtime:relativePath:db:) -> FileSyncDecision` — scan/event 共通の
    per-file 判定（preDecision → verifyHash → postHash → mtime CAS）。hash は `computeHashDetached` で off-main
    （`computeHashDetached` も `nonisolated` 化）なので @MainActor の event 経路からも安全に呼べる。CAS の
    repaired/no-op を `FileSyncDecision`（`.skip`/`.enqueue`/`.mtimeRepaired`/`.mtimeCASNoop`）で区別する
    （scan は repaired のみカウント、event は 3 種とも早期 return）。
  - `enqueueUpload(db:path:now:onConflict:)` — upload 1 行投入。**onConflict は scan=`.ignore`（リトライ中の
    attempts を巻き戻さない）/ event=`.replace`（処理中の同 path を置換＝L6 安定化）の差を呼び元が決める**。
  - `enqueueScanDeletions(db:foundPaths:now:) -> Int` — `knownPaths − foundPaths` を delete キューへ。
- **元関数に残すもの**: `performFullScan` のツリー走査・symlink skip・`PathValidator`・`HardcodedIgnoreRules`
  プレフィルタ・foundPaths 簿記・`Task.detached`/off-main・カウント集計。`processEventToQueue` の
  `.syncignore` reload + `triggerFullScan` ディスパッチ・`.deleted` / file-gone → `enqueueDelete`・除外判定の
  位置（event は判定後・scan は判定前）。
- **純粋移設の担保**: 各リファクタ直後に**既存テスト全通**で振る舞い不変を確認 → その後で新規テストを足し、
  各新規テストは**フェイルファースト**（分岐を故意誤配線して落ちる）で配線検出力を確認。新規テストは
  `RemoteDeletionTests` / `ReconcileWiringTests` / `ScanEventWiringTests`。
- **残ギャップ（@MainActor 直接駆動面なし＝スコープ外）**: `.syncignore` reload/triggerFullScan ディスパッチ、
  event の `.deleted` / file-gone → `enqueueDelete`、scan の巨大クロージャ本体（走査）。単一走査リライト
  （`docs/09` ネスト `.syncignore` の「効率: ツリー二重走査」）の前提だった「先に scan 結合テスト」は本タスクで満たした。
  → **走査本体は #64（2026-07-21）で `walkSyncTree` / `classifyAndEnqueue` として抽出・直接駆動テスト整備済み**（上記
  「フルスキャンの単一走査化」節）。event ディスパッチ面は残存。

### バージョン単一化と診断エクスポート（2026-06-19・PR #24）

- **バージョン単一ソース化**: `Tide/Info.plist` の `CFBundleShortVersionString` / `CFBundleVersion` を `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 参照にし、**バージョンは `project.yml` の build settings を唯一のソース**にした（plist 側に数値を二重定義しない・Xcode がビルド時に展開）。あわせて `NSHumanReadableCopyright` を設定、`LSApplicationCategoryType=utilities` を追加（アーカイブ時のカテゴリ未設定警告を解消）。About 表示・診断テキストはどちらも `Bundle.main` から動的取得するのでこの単一ソースに追従する。
- **About のアプリアイコン**: `NSImage(named: "AppIcon")`（バンドルのコンパイル済み asset catalog を直接引く）を一次ソースにし、解決できないときだけ `NSApp.applicationIconImage` にフォールバックする。**`NSApp.applicationIconImage` は LaunchServices のアイコンキャッシュ（バンドル ID 単位で古い dev ビルドのアイコンを保持しがち）を反映して古い絵を返すことがある**ため、現在のバンドルのアイコンを確実に出すには named 参照が要る（実機で旧アイコン表示を確認・差し替え済み）。`AboutWindowTests` が appiconset `"AppIcon"` の `NSImage(named:)` 解決を担保（`MenuBarPresentationTests` のアセット実在テストと同じ「無言の空画像」防止）。
- **診断エクスポート**（`Tide/Core/DiagnosticsExporter.swift`）: サポート用に診断テキスト + `sync-log.txt` + DB スナップショットを 1 つの `.zip` にまとめ、`NSSavePanel` でユーザが選んだ場所へ書き出す。
  - **セキュリティ境界（`security/low.md` L13）**: AWS 認証情報（Keychain）は一切扱わない（構造的に漏れない）。ただし DB スナップショットと sync_log には**ファイル名/相対パス・バケット名・deviceId が含まれる**ため、「含む/含まない」を Settings 文言と `diagnostics.txt` の Note に明示する（生成物を第三者へ送る前提のため・CLAUDE.md の path 非公開方針と整合）。
  - **DB スナップショット**: `LocalDatabase.snapshot(to:)` が `VACUUM main INTO ?`（`writeWithoutTransaction`＝VACUUM はトランザクション内不可）で WAL を取り込んだ一貫単一ファイルを出力。出力先は事前非存在であること。
  - **メインスレッドを塞がない**: env からの値収集だけ `@MainActor`（`export`）で行い、log 取得・staging 書き出し・スナップショット・zip 化は `nonisolated` の `writeArchive` に分離してメインアクター外で実行（CLAUDE.md「重い処理はメインから外す」）。
  - **純粋関数 + 結合テスト**: `diagnosticsText` / `logText` は純粋関数（`DiagnosticsExporterTests` がシークレット非混入を含め固定）。`writeArchive` は temp DB + サンプル入力で「zip が生成され diagnostics.txt / sync-log.txt / db.sqlite を含む」ことを結合テストで固定。zip 展開時の最上位フォルダ名は `Tide-Diagnostics`（UUID は親 temp 側に付ける）。

### 設定 export / import（C3・Issue #29・2026-07-01）

非機密のアプリ設定を 1 つの JSON（`Tide-Settings.json`）に書き出し / 読み込みする。主目的はクリーンインストール後の復旧と複数 Mac 間での設定の持ち回り。実装は `Tide/Core/SettingsTransfer.swift`。

- **セキュリティ境界**: AWS 認証情報（Keychain）と `deviceId`（端末固有 ID）と `setupCompleted`（状態）は **export 対象に含めない**（`Payload` にフィールドが無く構造的に漏れない）。新しい Mac へ移すときは AWS キーをウィザードで再入力する＝「認証情報は Data Protection Keychain のみ」の不変条件を崩さない（`DiagnosticsExporter` と同じ姿勢）。`SettingsTransferTests` が JSON に `deviceId` / `accesskey` / `secret` が出ないことを固定。
- **スキーマ版**: `Payload.schemaVersion`（現 `1`）。`decode` は **この値以下のみ受理**し、新しすぎる版は `TransferError.unsupportedVersion`、解釈不能は `.malformed` に正規化（呼び出し側が `LocalizedError` を UI 文言に使える）。`encode` は `.sortedKeys` + `.prettyPrinted` で差分を読みやすく。
- **接続 vs tunables の分離適用**: 接続設定（bucket / region / syncRoot）はローカル DB がバケットに紐づくため**ホットスワップしない**。`apply`（接続 + tunables 全部・エンジン未起動経路＝ウィザード専用）と `applyTunables`（polling / サイズ上限 / 帯域 / 通知のみ・エンジン稼働中でも安全）を分ける。
- **導線は 2 つ**:
  - **Settings 画面**（`SettingsWindow`）: 「Export Settings…」で書き出し、「Import Settings…」で読込。import は tunables を即適用 → UI 即反映（`loadStateFromConfig`）し、接続が現設定と異なるときだけ `env.pendingImportedSettings` に payload を載せて `openWindow(id:"setup")`（ホットスワップ回避＝ウィザードで再プロビジョニング）。
  - **セットアップウィザード**（`SetupWizardWindow`）: 「Import settings…」で接続フィールドを事前充填（新 Mac の主経路。AWS キーだけ手入力）。Settings → ウィザードのハンドオフ（`env.pendingImportedSettings`）の消費は **`.onChange(of:initial:true)`**（`.onAppear` ではない）。`"setup"` は単一・常駐の `Window` で、既に開いている状態で `openWindow(id:"setup")` を呼んでも `.onAppear` は再発火しない＝事前充填が無言で失われ、未消費 payload が将来の appear まで居残る（#46 レビュー指摘）。`initial:true` で「初回 appear（先に payload を立ててから開く）」と「既開で後から payload が立つ」の両方を消費し、消費後 nil クリアで居残りも防ぐ。
- **IO 経路**: 出力先は `NSSavePanel`、入力元は `NSOpenPanel`（`.json`）でユーザが選んだ場所のみ。LSUIElement なので panel 前に `NSApp.activate(ignoringOtherApps:)`。

### 削除済みファイル一覧の軽量キャッシュ（C3 (b)・Issue #29・2026-07-01）

「Deleted files」タブは `listObjectVersions` で `files/` 全体を毎回フル列挙する（巨大バケットで体感が悪い）。直近のフル列挙結果をスナップショットとして永続化し、タブを開いた瞬間に即表示・Refresh で再列挙する軽量キャッシュを追加（実装は `Tide/Core/DeletedFilesCache.swift`）。**増分インデックス（削除伝播パスへの hook）ではなく、削除系コードに触れない低リスクなキャッシュ**を選択（#29 で user 選択）。

- **保存場所**: `~/Library/Caches/Tide/deleted-files-cache.json`。派生データ（S3 からいつでも再生成可能）なので Caches。`factoryReset` が `Caches/Tide` ごと消す＝キャッシュも自動で消える。OS が Caches を purge しても次回 Refresh で再生成。
- **中身**: `schemaVersion` + `bucket` + `updatedAt` + `[FileVersionHistory]`（削除済みファイルの相対パス + 版メタデータ）。**認証情報は無い**。露出はローカル DB が既に持つパスメタデータと同等。`FileVersion` / `FileVersionHistory` を `Codable` 化して往復。
- **bucket キー**: `load(bucket:)` は現在 bucket と `payload.bucket` が一致したときだけ通す（純粋関数 `validate`）。別バケットへ切替後に旧バケットの削除一覧を出さない。スキーマ不一致・壊れ・欠落はすべて nil（無効）扱いのベストエフォート。
- **更新タイミング**: フル完走（`completedFully`＝最終ページまで列挙）したときだけ `save`（途中キャンセル/エラーの部分結果は保存しない）。`restoreDeleted` / Versions タブの `restore`（#47 レビュー #5＝両復元経路で対称）が原パス復元で一覧から外したときは、`updatedAt` を進めずに（単発除去でフル再列挙ではない）スナップショットだけ整合させる。
- **中断/失敗時の復帰（#47 レビュー #1）**: スキャン開始時に直前一覧を `preScanDeleted` に退避し、**未完走（cancel/error）なら一覧をそれへ戻す**。`deletedCacheUpdatedAt` は完走時しか進めない＝「空の一覧＋古い Last updated を断定表示（No deleted files.）」という後退を作らない。cancel は世代を進めて in-flight 書込を捨てるため、戻しは `cancelDeletedScan` 側でも行う（完了ブロックは世代不一致で来ない）。
- **書込の直列化とタイムスタンプ確定（#47 レビュー #3/#4）**: 全キャッシュ書込は 1 本の `cacheSaveTask` チェーン（前の `.value` を待つ FIFO）で直列化＝scan 完了 save と restore 後 save の last-writer-wins を防ぐ。`advanceTimestamp` のときは**書込成功後に** `deletedCacheUpdatedAt`/`deletedCacheBucket` を確定（失敗時に Last updated だけ進む齟齬を作らない）。保存 bucket は走査/読込時に確定した `deletedCacheBucket` を使う（#47 レビュー #2＝表示中の bucket 変更で旧一覧を新キーへ汚染しない）。
- **読込タイミング**: `VersionHistoryWindow` の `.task`（オープン時 1 回）で `loadDeletedCache`。未スキャン・一覧が空・`deletedCacheUpdatedAt == nil` のときだけ反映＝ライブなスキャン結果を後追いで潰さない。実 IO（読込/保存）は `Task.detached` で main から外し、state 更新は MainActor 継承 Task 上で行う。
- **UI**: キャッシュありなら「Last updated …（相対時刻・自動更新）」+ ボタンは Refresh、未列挙なら従来どおり「Search deleted files」。純粋部分（encode/decode/validate）は `DeletedFilesCacheTests` で固定。
