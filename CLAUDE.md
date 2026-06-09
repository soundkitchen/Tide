# Tide — AI エージェント向けガイド

このファイルは Claude Code / 互換エージェント (`AGENTS.md` と同一内容) が
セッション開始時に読み込む前提で書いてある。会話履歴や `docs/` の重要点、
これまでに確立した実装ルールを集約した。

---

## 🚨 大原則 (1): ドキュメントとコミットメッセージは必ず日本語で

**このリポジトリで AI エージェントが生成する以下のものは、すべて日本語で書く**。
英語で書いてはならない。例外なし。

- **Git のコミットメッセージ**（subject / body の両方）
- **Markdown ドキュメント**全般: `CLAUDE.md` / `AGENTS.md` / `README.md` / `docs/*.md` / `security/*.md` / `tmp/*.md`
- **PR / Issue / Slack 等への投稿**（必要時）
- **新規に書くコードコメント**（既存の英語コメントを機械的に翻訳する必要はないが、追加・修正時には日本語へ）
- **ログメッセージ**は英語のままで構わない（OS Log の慣習に従う）。**プログラム識別子（型名・変数名・キー名）は英語のまま**。

迷ったときの判断基準:
- ユーザの目に触れる人間向けテキストは日本語
- 機械が読む識別子・コードは英語

---

## 🚨 大原則 (2): 実装変更はドキュメント反映とセットでコミット

**コード変更を含むコミットを作る前に、関連するドキュメントが最新かを必ず確認する。**
実装とドキュメントが乖離した状態でコミットしてはならない。

確認の対象:
- `docs/*.md` — 仕様レベルの記述。実装がここから外れたら、同じコミットで docs も更新
- `CLAUDE.md` の「会話で確定した実装決定」セクション — 仕様レベル未満の運用ルール
- `security/*.md` — セキュリティ関連の変更があれば該当項目に **Status:** 行で反映
- `README.md`（ある場合）/ `Makefile` のヘルプテキスト

コミット前チェックリスト:
1. `make build && make test` が通る
2. **`docs/` を grep して、変更箇所の仕様記述を確認したか**
3. 新規の運用上の決定があれば CLAUDE.md に追記したか
4. セキュリティ周りなら `security/` の Status を更新したか

「あとでまとめて直す」は禁止。**今のコミットに含める**。

---

## 1. プロジェクト概要

- **目的**: macOS のクリーンインストール後の復旧を主目的とした、Dropbox 風 S3 同期ツール。
- **アーキテクチャ**: macOS 26+ 専用、Swift 6（strict concurrency: complete）、SwiftUI、メニューバー常駐 (`LSUIElement = YES`)。
- **設計の原典**: `docs/00-OVERVIEW.md` から `docs/06-SETUP-AND-BUILD.md` まで。**仕様に迷ったら先に docs/ を読むこと。**
- **マイルストーン**: 
  - M1 ローカル → S3 一方向アップロード（実装済み）
  - M2 ダウンロード / 復元 / ポーリング（実装済み・MVP ゴール）
  - M3 双方向同期 / 競合解決 / マルチパート（サブ A〜E 実装済み: マルチパート / `.syncignore` / 3-way merge / 中断・再開 / 帯域制御。**M3 完了**。§8 の据え置き数件あり）
  - M4 運用機能と磨き込み（未着手）

### 主要な確定パラメータ
- Bundle ID: `org.izukawa.Tide`
- DEVELOPMENT_TEAM: `G5G54TCH8W`
- ローカル DB: `~/Library/Application Support/Tide/db.sqlite`（GRDB.swift / WAL）
- ダウンロード一時ディレクトリ: `~/Library/Caches/Tide/tmp/`（同期ルートと別ボリュームの時のみ `<syncRoot>/.tide/tmp/` にフォールバック）
- S3 マニフェスト: `.tide/index.json` + `.tide/shards/XX.json`（XX は SHA-1 先頭 1 バイト、256 シャード）
- ローカル相対パスは常に POSIX、ハッシュは SHA-256 hex 小文字、時刻は ISO8601 UTC

---

## 2. ビルド・テスト・実行

**Makefile を経由するのが基本。** `make help` で一覧。

| 目的 | コマンド |
|---|---|
| Xcode プロジェクトを再生成 | `make generate` |
| Debug ビルド | `make build` |
| ユニットテスト | `make test` |
| 起動 / ja 起動 / en 起動 | `make run` / `make run-ja` / `make run-en` |
| ローカル状態を全消し | `make reset` |
| reset → build → 起動 | `make fresh`（新規セットアップ検証の定番） |

### 重要な制約

- `Tide.xcodeproj/` は `xcodegen` が `project.yml` から **毎回生成する**。git でも追跡しているが **直接編集しない**（再生成で上書きされる）。
- **Swift ファイルを追加 / 削除 / リネームしたら `make generate`** を踏まないと Xcode プロジェクトに反映されない。再生成後の `Tide.xcodeproj` の差分も git に乗せる。
- `xcodebuild` を直接叩く時は **`-skipPackagePluginValidation -skipMacroValidation` が必須**（aws-sdk-swift が依存する smithy-swift のビルドプラグインの検証が CLI からは初回承認できないため）。さらに **`-allowProvisioningUpdates`** も必要（Keychain entitlement のためにプロビジョニングプロファイルが要る。下記）。Makefile はこれらを内包している。
- macOS GUI で初回のみ Xcode から SmithyCodeGeneratorPlugin の承認を求められる。

---

## 3. コード規約

### Localization
- 文言は **`Tide/Resources/Localizable.xcstrings`** に集約（en source / ja 翻訳済み）。
- SwiftUI の `Text("…")`, `Button("…")`, `TextField("…", …)` などの **リテラル引数は自動でローカライズ**される。
- 関数返値の `String` を `Text(value)` / `Button(value)` に渡すケースは **`String(localized: "…")` で明示的に解決する**（さもないと verbatim 表示になる）。
- 既存キーは `extractionState: "manual"` を付けて Xcode の自動 purge を防いでいる。

### Logging（os.Logger）
- サブシステム: `org.izukawa.Tide`。カテゴリ: `sync` / `s3` / `database` / `ui` / `watcher`。
- エラー / パス / リモートデータ由来の文字列は **必ず `privacy: .private`** で補間する。`.public` を使わない。
- 例:
  ```swift
  AppLogger.sync.error("Foo failed: \(String(describing: error), privacy: .private)")
  AppLogger.s3.info("Uploaded \(path, privacy: .private) (\(size) bytes)")
  ```

### Concurrency
- 全面的に async/await + actor。
- `SyncEngine` は `@MainActor @Observable`。重い処理は `Task.detached(priority: .utility)` でメインから外す。
- `DebounceQueue` は actor。**`fire` で `Task.detached` を経由して `emitter` を呼ぶ**（さもないと timer task の cancellation が下流の GRDB / await に伝播して `CancellationError` を起こす）。
- C コールバック（FSEvents 等）の self ブリッジは `Unmanaged.passUnretained` + `fromOpaque` パターン。

### セキュリティゲート（**外さない**）

`security/` の対応サマリ (`security/README.md` の status 表) を参照。特に下記は **常に守る**:

- **`PathValidator.resolveSafely(relativePath:syncRoot:)` を、リモート由来の path がローカル FS 操作に到達する全入口で呼ぶ**（Downloader / Uploader / SyncEngine / ManifestReader）。`..` / 絶対パス / NUL / バックスラッシュ / 空コンポーネントを拒否し、解決後の URL が syncRoot 配下にあることまで検証する。
- **`PathValidator.validateShardId(_:)` を、`shardId` が S3 キーに組み立てられる全入口で呼ぶ**（S3Client.getShard/putShard/deleteShard、ManifestReader.read）。`^[0-9a-f]{2}$` 強制。
- **シンボリックリンクは絶対に追従しない**: `SyncEngine.performFullScan` の enumerator で `.isSymbolicLinkKey` を取り、symlink なら `skipDescendants()` + `continue`。Downloader の書き込み先（最終コンポーネント）がシンボリックリンクなら拒否。
- **書込・削除経路は `PathValidator.resolveForWrite(relativePath:syncRoot:)` を通す**（Downloader の `download` / `applyRemoteDeletion` / `renameLocalForConflict`）。`resolveSafely` は字句検証のみで symlink を解決しないため、**祖先ディレクトリの symlink 経由のルート脱出**（最深の既存祖先の実パスが syncRoot 実パス配下か）も拒否する（F2 / M6）。
- **Uploader はアップロードを `NoFollowFileReader`（`open(O_RDONLY | O_NOFOLLOW)`）の単一 FD で行う**。最終コンポーネントが symlink なら ELOOP（`FileOpenError.isSymbolicLink`）で拒否してキューから外す。ハッシュ計算と本体読込/パート送信が同一 FD なので 2 回 open の TOCTOU 窓は無い（M5 / F3 / L9 解消済み）。祖先 symlink は対象外＝`resolveSafely` とスキャン skip に委ねる。
- **新しい dotfile / 拡張子で「機密が紛れ込みそう」と思ったら、`HardcodedIgnoreRules` に即追加**。
- `PutObject` は常に `serverSideEncryption: .aes256` を指定。**マルチパートも `createMultipartUpload` で同様に SSE-S3 を必ず付ける**（漏らすと暗号化なし保存）。
- Keychain クエリは `kSecUseDataProtectionKeychain=true`, `kSecAttrAccessible=AfterFirstUnlock`, `kSecAttrSynchronizable=false` を必ず含める。
- `factoryReset` は Application Support / Caches / UserDefaults / Keychain を完全に消す（`make reset` と挙動を揃える）。

### SwiftUI 起き上がり
- **メニューバーポップオーバーから `openWindow(id:)` を呼ぶときは必ず `NSApp.activate(ignoringOtherApps: true)` を前置する**。LSUIElement = YES のアプリだとアプリがフォアグラウンドに来ておらず、ウィンドウが見えないまま開かれる事故が起きる。

### Time-of-check vs Time-of-use
- アップロードのハッシュ計算と本体読込/パート送信は **`NoFollowFileReader` の単一 `O_NOFOLLOW` FD** から行い、2 回 open の TOCTOU を解消済み（M5 / F3 / L9、2026-06-02）。`O_NOFOLLOW` は最終コンポーネントのみ有効（祖先 symlink は別レイヤ）。

---

## 4. 作業の進め方（このリポジトリ固有のフロー）

1. **`docs/` に書いてあることは spec として扱う**。逸脱する場合は必ずユーザに確認。
2. **設計判断（命名 / フォルダ位置 / IAM 範囲 / UX 分岐 など）はユーザに聞いてから決める**。`AskUserQuestion` ツールを活用。「実装中に設計上の判断が必要になったら、勝手に決めずに必ず聞いてください」がユーザの明示の希望。
3. **ステップごとにコミット可能な単位で進め、節目で「次に進めますか？」と確認**。
4. セキュリティに関わる変更を入れたら、対応箇所を `security/{critical,high,medium,low}.md` の該当セクションに **Status:** 行で反映する。
5. 受け入れテストは `tmp/MX-動作チェックリスト.md` に手順を書き出して、全項目チェック後に削除する運用。
6. xcstrings に新規キーを足す時は **`extractionState: "manual"`** を必ず付ける。

---

## 5. ハマりやすいポイント

- **xcstrings に重複キーを作らない**。手で編集する前に既存キーを `grep` で確認する（特に "Region" のような汎用ラベル）。
- **`xcodegen` 再生成を忘れる**と「Cannot find type X in scope」が SourceKit に出続ける。新ファイルを足したら必ず `make generate`。
- **`make test` は本体アプリ（`Tide.app`）をテストホストとして起動する**（`project.yml` の `TEST_HOST`）。そのままだと `applicationDidFinishLaunching` の eager bootstrap が走って**テスト中に実 S3 と同期してしまう**ため、`AppEnvironment.bootstrap()` 冒頭で `ProcessInfo.processInfo.isRunningXCTests`（`XCTestConfigurationFilePath` の有無で判定）なら no-op で抜ける。テストで実 SyncEngine を立ち上げたい場合はこのガードを踏まえて設計する。
- **`AppleScript` でメニューバーポップオーバーをクリックする検証**は、`activate` 系で popover が dismiss しやすいので不安定。手動 UI 確認の方が早いことが多い。
- **GRDB の `MutablePersistableRecord.insert` は `didInsert` を実装しないと auto-increment id が反映されない**（`UploadQueueRecord` / `SyncLogRecord` で対応済み）。
- **Dropbox 配下にプロジェクトを置いている**ため、ビルド成果物 (`build/`) が Dropbox 同期に乗らないよう `.gitignore` および Dropbox 側で除外しておくのが望ましい。
- **Keychain entitlement とデバイス登録**: AWS 認証情報は Data Protection Keychain（`kSecUseDataProtectionKeychain=true`）に保存する。`project.yml` の `entitlements` から `Tide/Tide.entitlements`（`keychain-access-groups: $(AppIdentifierPrefix)org.izukawa.Tide`）が生成され署名に埋め込まれる。これがないと実行時に **`OSStatus 34018 (errSecMissingEntitlement)`**。automatic signing でこの entitlement を付けるには Mac App Development プロビジョニングプロファイルが要り、**この Mac が開発者アカウントに登録**されている必要がある。未登録だとビルドが `Device "…" isn't registered` で失敗する。**初回だけ Xcode GUI で Tide ターゲットを一度ビルド**すれば Mac が自動登録され、以後は CLI（Makefile の `-allowProvisioningUpdates`）でも通る。詳細は `docs/06-SETUP-AND-BUILD.md`。

---

## 6. ファイル / ディレクトリの役割

| パス | 役割 |
|---|---|
| `project.yml` | xcodegen の唯一のソース。Bundle ID / 依存 / ターゲット設定 |
| `Makefile` | ビルド / テスト / リセットの統合 |
| `Tide/App/` | エントリポイント / `AppEnvironment` |
| `Tide/UI/` | SwiftUI ビュー（MenuBar / Setup wizard / Settings） |
| `Tide/Core/` | SyncEngine / FileWatcher / DebounceQueue / PathValidator / TideTmpDirectory 等 |
| `Tide/Storage/` | GRDB DB / KeychainStore / ConfigStore / Migrations |
| `Tide/S3/` | S3Client / Uploader / Downloader / ManifestReader / KnownRegions |
| `Tide/Models/` | 構造体（AWSCredentials / SyncStatus 等） |
| `Tide/Resources/` | `Localizable.xcstrings` / アセット |
| `TideTests/` | ユニットテスト |
| `docs/` | 設計書（spec） |
| `security/` | セキュリティレビューと対応サマリ |
| `tmp/` | 動作チェックリスト等の使い捨て（`.gitignore` 済み） |

---

## 7. 会話を通じて確定した実装決定（docs/ に書ききれていない補足）

`docs/` の仕様書本文を超えて、会話のキャッチボールで確定した運用上の決定をここに集約する。
新規実装で挙動を変える時は、対応する `docs/*.md` も同時更新（→ 大原則 (2)）。

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
- **上限超過は黙ってスキップしない**: `SyncError.fileTooLarge` を投げ、`SyncEngine.handleProcessingFailure` がリトライせずに `recentErrors` へ明示 + `sync_log` error + キュー除去（「このファイルはバックアップされていない」を可視化）。バックアップツールでサイレントな取りこぼしは最悪なので必ず見せる。
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

### 競合解決（3-way merge・M3 サブ C）
- **競合解決の判定は純粋関数 `ThreeWayMerge.decide(base:local:remote:) -> MergeDecision` に一本化**（`Tide/Core/ThreeWayMerge.swift`）。`reconcileRemoteEntry`（pull 側）と `applyRemoteDeletion`（削除側）の両方がこれを通す。**ベース = `FileRecord.sha256`（ローカル DB）**、マニフェスト schema は拡張しない。判定ロジックを副作用から切り離し、全分岐を `ThreeWayMergeTests` で網羅（`IgnoreDecision`/`PartPlan` と同じパターン）。挙動は旧 M2 表（`docs/04-SYNC-LOGIC.md`）と 1:1 一致。
- **アップロード側に並行更新検出は無い（last-writer-wins ギャップ・据え置き）**。競合検出は pull/削除側のみ。詳細は第 8 節。

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
- **不変条件: 「`FileRecord.mtime` = 最後に同期した時点のローカル stat mtime」**。マニフェスト `mtime` は ISO8601 秒精度（fractional なし・`Manifest.swift` の `ISO8601.format`）なので、これで DB を上書きしてはならない（フルスキャンの `< 0.001` 比較が常に外れ、無変更ファイルが毎起動再アップロードされる。§8 の修正済み項目参照）。pull の内容一致時の DB 最新化（`Downloader.updateDBEntryWithoutWrite`）は**ローカル stat 実値**を記録する。stat は **sha 計算の前に**行う（ハッシュ中の書換でも「旧 mtime + 旧 sha」の組で残り次回再検出される安全方向。後 stat は「新 mtime + 旧 sha」で取りこぼしが恒久化する）。
- **変更判定は純粋関数 `ChangeDetector`（`preDecision`/`postHash`）に集約**し、`performFullScan` / `processEventToQueue` の両経路で共用（docs/04 の SHA ゲート仕様の実装）。size 一致 + mtime 不一致のときだけ SHA を再計算し、一致なら **CAS（`LocalDatabase.refreshMtimeIfShaUnchanged`）で mtime のみ修復**してアップロードしない（`lastSyncedAt` 保持・sha 不一致なら no-op = 並行 pull の更新を巻き戻さない）。size 不一致は hash せず直接 enqueue（sha が一致し得ないため仕様と同義）。`processEventToQueue` は @MainActor なので **hash は `Task.detached` 経由**。
- **`parseISO8601`（`Downloader.swift`）は fractional seconds をパースできず nil → now フォールバックする**。マニフェスト mtime に fractional を足す変更は禁忌（フォーマット側だけ変えるとパース全滅）。

### torn upload と in-flight collapse の解消（L6・2026-06-09）
- **キュー行のライフサイクルは `item.id` 基準で扱う（`path` 基準にしない）**。enqueue は `INSERT OR REPLACE`（`upload_queue.UNIQUE(path)`）で、処理中に届いた新イベントを**新しい AUTOINCREMENT id の行**に置換する（＝完全版を上げ直せという正当な指示）。完了/失敗処理（`Uploader.processUpload`/`processDelete`、`SyncEngine.handleProcessingFailure` の retry/give-up/size-limit、`convertQueueItemToDelete`）が `path` 基準で削除・更新すると、旧 in-flight 行の完了がこの新行まで巻き込み消去し、ローカル≠DB≠リモートの**無エラー乖離**になる。**id 基準なら新行は残り次周回で再処理されて自己修復**する。enqueue 側（`handleDebounced`）は `@MainActor`＋GRDB 単一ライタで直列なので、`DebounceQueue.fire` の並行はこの不具合と無関係（当初の誤診）。
- **torn を決して“コミット”しない安定化ゲート（A-detect）**。アップロードは単一 `O_NOFOLLOW` FD から読むが、読込中に書き換えられると torn な内容を S3 にコミットし得る。**読了後に同 FD を再 `fstat` し、開始時の (size, mtime) と size 変化 or mtime 前進があれば不安定**とみなす（純粋関数 `StabilityCheck.isStable`・`Tide/Core/StabilityCheck.swift`）。シングルパートは `putObject` の**前**に判定して不安定なら PUT しない（現行 S3 版を torn で上書きしない）、マルチパートは `MultipartUploader.upload` に `expectedStat` を渡し `completeMultipartUpload` の**前**に判定して不安定なら **abort +（resume 時）checkpoint クリア**（complete しないので現行版は無傷、新 mtime でフル再開）。いずれも `SyncError.fileChangedDuringUpload` を投げる。瞬断等の従来失敗は従来挙動（resume なしのみ best-effort abort）を維持し、**不安定だけ** resume でも abort+clear する（stale な MPU を保持しない）。**マルチパートは read ループ内で逐次 early-bail**（読了量 > 開始時 size＝成長／`reader.info()` の mtime 前進＝in-place 書換）し次パート PUT 前に throw する＝成長/変化し続ける大ファイルで「満額 PUT → 全 abort」を毎リトライ繰り返す課金・帯域の浪費を避ける（PR #14 レビュー Medium）。再検査間隔と警告閾値は純粋関数 `SyncEngine.unstableRetryDelay`/`shouldWarnUnstable`（比例設計のため初回警告は実際 ~48s 付近）。
- **安定しないファイル（ログ/DB 等）は give-up させず延期＋可視化**。`handleProcessingFailure` は `fileChangedDuringUpload` を **`attempts` に載せず**（5 回 give-up で恒久未バックアップにしない）、`LocalDatabase.deferUnstableQueueItem(id:nextRetryAt:)` で延期する（`attempts`/`enqueuedAt` 保持・`nextRetryAt` のみ前進）。再検査間隔は `min(max(3s, now − enqueuedAt), 300s)`＝**保留経過に比例**させ巨大ファイルの無駄な全読みを抑える（スキーマ変更なし）。保留が 30s を超えて安定しなければ「まだバックアップされていない」を `recentErrors`/`sync_log` に **1 回だけ**見せる（in-memory `unstableWarned` で dedup、アイドル周回の `pruneUnstableWarned` でキューから消えた path を間引き＝再エピソードで再警告可能）。＝**torn を出さず取りこぼしも黙らせない**。

---

## 8. 既知の据え置き項目

- **C3 後半**: HTTPS 強制バケットポリシー（`PutBucketPolicy` で `aws:SecureTransport=true`）。SDK 自体は HTTPS 既定で送るので緊急度は低い。
- **H3**: 静的 AWS キー → STS / IAM Identity Center への構造的置き換え。M3 以降で要検討。
- **M5 / F3 (L9)**: ✅ 解消済み（2026-06-02）。M3 マルチパート対応で `NoFollowFileReader`（`O_NOFOLLOW` の単一 FD）に置換し、ハッシュ計算と本体読込/パート送信を同一 FD 化＝2 回 open の TOCTOU を構造的に解消。`O_NOFOLLOW` は最終コンポーネントのみ有効（祖先 symlink は別レイヤ）。
- **中断・再開（サブタスク D・進行中）**: D1（`transfer_state` + `TransferStateStore`）/ D2（アップロードの再起動またぎ再開）/ D3（ダウンロードの Range 再開）は ✅ 実装済み（2026-06-04）。アップロードは `MultipartUploader.ResumeContext` で UploadId と完了パートを checkpoint。ダウンロードは `Downloader` が決定的 tmp（`dl-<sha(path)>.part`）＋ `transfer_state`（tmp_path/expected_etag）で、永続行が現エントリ etag と一致すれば `streamObject(rangeStart:)` で `Range: bytes=N-` 再開し、既存プレフィクスを読み直して全体 SHA を復元、最後に必ず期待 SHA と突合。ネットワーク失敗は部分 tmp と行を保持して次回再開、etag 不一致/SHA 不一致/サイズ超過/404 は破棄して仕切り直す。D4 進捗 UI（下記「転送進捗 UI」）と D5（`SyncEngine.start()` 冒頭の `pruneOrphanTransfers` で消えたファイル/古い行/宙ぶらりん UploadId を best-effort 掃除 + `security/low.md` L12 レビュー）も ✅ 実装済み。**PR #4 レビュー反映（2026-06-05）**: download 失敗時に `recordDownloadProgress` を配線して `bytes_done`/`updated_at` を前進（prune の stale 判定が実活動を反映）、fresh の tmp 書込を `O_NOFOLLOW|O_EXCL` 化（symlink 追従窓を解消）、空 etag では再開しないガード、`applyProgress` を純粋関数 `TransferProgress.reduce` に切り出して `TransferProgressTests` で out-of-order 耐性を固定。**実機受け入れチェックリストも全項目消化済み（✅ 2026-06-07・チェックリストは運用ルールどおり削除）＝サブタスク D 完了**。消化中に発見した項目は本節下方の 3 項（L6 実害化／DL prune の invalidate 漏れ（✅ 修正済み 2026-06-07）／毎起動再アップロード（✅ 修正済み 2026-06-08））を参照。詳細は `docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク D。
- **サブD PR #4 レビューの据え置き（Low/nit）**: (a) **complete 直後クラッシュで stale UploadId 残**: `completeMultipartUpload` 成功 → `clearUpload` の間（DB 書込 1 回分の窓）で kill されると、完了済み UploadId の行が残り、次回 resume の `completeMultipartUpload` が `NoSuchUpload` で空振り（7 日の stale prune or ファイル mtime 変化まで）。本体は S3 に安全に上がっているので Low・自己回復。正しく塞ぐには「complete 時の `NoSuchUpload` は成功扱い」だが、その時 `PutObjectResult`（etag/versionId）が無くマニフェスト更新に `HeadObject` 復旧が要る（一行では塞げない）。(b) **進捗 begin/end 再順序のゴースト**: 最初の `.begin` Task が最後の `.end` Task より後に実行されると 0% エントリが `stop()` まで残る（純粋 reducer では本質的に塞げない Task 順序問題・ほぼ起きない nit）。
- **中断ダウンロードの自動再開（2026-06-05・受け入れテストで発見 → ✅ 修正済み）**: 旧挙動では中断 DL が**再起動だけでは自動再開しなかった**。`Downloader` の Range 再開機構自体は正しいが、それを呼ぶ pull 経路が中断ファイルを見なかった: `ManifestReader.read()` は**シャードを fetch した時点で `shard_state` に「取得済み」を記録**する（DL 完了前）ため、DL が中断されると (1) そのシャードは次回 pull で「未変化」とキャッシュ判定され S3 から再取得されず未変化シャードは**ローカル DB から再構築**されるが、(2) 中断ファイルは DL 未完で**ローカル DB レコードが無い** → reconcile されず → `Downloader.download`（Range 再開）に到達せず、`transfer_state` 行と部分 tmp が取り残された（クリーンインストール復旧が中断すると一部ファイルが永久欠落しうる重大バグ）。**修正（方針④）**: `SyncEngine.pruneOrphanTransfers` で、prune されない（= tmp あり・新しい＝再開可能な）download 行について、その path のシャードの `shard_state` を invalidate する。**行は削除せず etag を空 sentinel に更新する**（PR #9 レビュー ③）: `cached[S] = "" ≠ remote etag` で必ず再 fetch させつつ、S がリモートから丸ごと消えた場合の removed-shard 検出（`removed = cached − remote`）も温存する（行を消すと S が cached から消え、S 配下の削除伝播が永久に飛ぶ）。空 etag は実 S3 etag と衝突しない。起動時 prune は pull の前に走るので、直後の起動 pull がそのシャードを S3 から再取得 → 中断ファイルを reconcile → 既存 tmp で Range 再開、という既存機構をそのまま再利用する（新たな再開コード経路を増やさない）。同シャードの他ファイルは reconcile で localMatchesRemote → no-op で安全。実機で「shard_state 手動クリア無し・再起動のみ」で Range 再開・SHA 一致を確認。
  - **セッション中の再 arm（PR #9 レビュー ②・✅ 修正済み 2026-06-07）**: 旧挙動では再 arm が**起動時 `pruneOrphanTransfers` でのみ**走り、セッション中の DL ネットワーク失敗はシャードがリモートで変化するか再起動するまで取り残された。**修正**: sentinel 化を `LocalDatabase.invalidateShardCache(forPath:)` に共通化し、`Downloader.download` のネットワーク失敗 catch（部分 tmp を保持する resumable 失敗・`recordDownloadProgress` 箇所）からも呼ぶ→次の poll/wake/network-up pull が再取得→reconcile→Range 再開。**破棄系（SHA/実サイズ不一致・tooLarge・404）は再 arm しない**（決定的に再失敗するためリトライストーム回避＝シャード etag 変化による自然回復に委ねる。`reconcileRemoteEntry` の catch 案を採らなかった理由も同じ）。`DownloaderTests` で再 arm／非再 arm 両スコープを回帰固定。
- **手動「S3 から取得」の pull 中サイレントドロップ（PR #9 レビュー ④・✅ 修正済み 2026-06-07）**: pull 進行中の手動押下は `pendingManualPull` で pending 化し、現 pull 終了後にもう 1 周する（coalescing）。UI は `isRemotePulling`（@Observable）で「Pull from S3」→ スピナー + 「Pulling…」に切替（enabled のまま＝押下が coalescing の入口）。詳細は §7「リモート pull の単一ゲート化」と `docs/04-SYNC-LOGIC.md` のトリガー節。
- **F1 (L8)**: ✅ 解消済み（2026-06-04）。`.syncignore` の照合から `NSRegularExpression` を廃し、グロブをトークン列へコンパイルして reachable-set DP で評価する線形時間照合（`O(パターン長 × パス長)`、バックトラッキング無し）へ置換＝ReDoS を構造的に解消。`parse` の各上限は防御的サニティ上限として保持。意味論は旧 regex 実装との differential fuzz で同値確認（`SyncIgnoreMatcherTests`）。
- **F4 (H2 UI 残)**: UI の `recentErrors` / `.error` が生 SDK エラー文字列（バケット名・キー・リージョン等のメタデータ。認証情報は含まない）を表示。**意図的に保持**（デバッグで実利が大きく、OS Log は `.private` 化済みで UI が事後コピーの実質唯一ソース。重要度 Low・本人画面のみ）。**他人配布／単一ユーザ開発を抜ける前に再評価**し、是正は単純削除でなく「UI は分類サマリ + 詳細をオンデマンド展開/コピー」案で（`S3ErrorClassifier` / `SyncError.description` 流用。`security/high.md` H2 残存項参照）。
- **アップロード側の並行更新検出（last-writer-wins ギャップ）**: M3 サブ C で競合解決を `ThreeWayMerge` に形式化したが、適用は pull/削除側のみ。同一ベースから 2 台が編集すると後勝ちでマニフェストが上書きされ、先に上げた側は次回 pull で「local == base＝未編集」判定で相手版を取り込み、ローカル編集がワーキングコピーから消える（S3 バージョン履歴には残る）。対称化＝`Uploader.processUpload` 直前にも `ThreeWayMerge` を適用（per-upload リモートマニフェスト読み + アップロード側コンフリクト経路）は別サブタスク。
- **reconcile/削除の配線部が未結合テスト**: `ThreeWayMerge.decide` の純粋ロジックは `ThreeWayMergeTests` で全分岐網羅したが、`reconcileRemoteEntry` / `applyRemoteDeletion` の「`MergeDecision` → 実 I/O」switch マッピングは結合テストが無い（取り違えを回帰検出できない）。`Downloader` へ最小 S3 シーム（`MultipartUploadClient` 同様）を切れば削除側は temp DB + temp syncRoot で結合テスト可能。別サブタスクに据え置き（PR #3 レビュー指摘 2）。**同系で `performFullScan` / `processEventToQueue` の「`ChangeDetector.PreDecision`/`PostHash` → CAS or enqueue」switch 配線も未結合テスト**（純粋関数・CAS・Downloader 早期 return は固定済み。scan 本体は巨大クロージャで注入面が無く、テスタブル化はこの項の対応と合わせて。PR #12 レビュー nit-3。配線テストは PR #11 で実欠陥 `clearUnknownDirections` を掘り当てた前歴あり）。
- **ローカル hash 経路の symlink 追従の一括 NoFollow 化（据え置き・無害確認済み）**: scan / event の SHA ゲートと `Downloader.currentLocalSha`（reconcile 経路）の `HashCalculator.sha256(of:)` は `O_NOFOLLOW` なしで、チェック〜hash の間の symlink 差し替えでリンク先を読みうる。**帰結は無害**（hash 一致 → mtime 修復のみ・アップロードなし／不一致 → enqueue → Uploader の `NoFollowFileReader` が ELOOP 拒否。hash 値はどこにも出ない）。対応するなら `NoFollowFileReader` 系への一括寄せを将来タスクで（PR #12 レビュー nit-2）。
- **L1**: App Sandbox 化。security-scoped bookmark + entitlement の正規対応は M3+。
- **L6（✅ 修正済み 2026-06-09）**: 書込中ファイルの torn upload + in-flight collapse。**2026-06-07 の受け入れテストで実害再現**: 成長中の 1.2GB を watcher が拾い 850MiB 時点の千切れた内容をアップロード、書込完了後の再 enqueue が処理中行との `UNIQUE(path)` collapse で飲み込まれて無エラー乖離になった。**真因は 2 欠陥**（当初疑った `DebounceQueue.fire` の並行は無関係＝`handleDebounced` は `@MainActor`＋GRDB 単一ライタで直列）: ① 完了/失敗処理がキュー行を `path` 基準で削除 → 処理中に置換された新 id 行を巻き込み消去。② 成長中ファイルの torn read。**修正（3 コミット）**: ①→キュー行ライフサイクルを **`item.id` 基準**に統一（新行は巻き込まれず次周回で自己修復）。②→**安定化ゲート（A-detect）**: 単一 FD で読了後に再 `fstat` し size 変化 or mtime 前進なら torn とみなし、シングルパートは PUT 前・マルチパートは complete 前に弾く（`SyncError.fileChangedDuringUpload`、`StabilityCheck`）。安定しないファイルは give-up させず延期＋未バックアップを 1 回可視化（§7「torn upload と in-flight collapse の解消」参照）。`security/low.md` L6 / `docs/04-SYNC-LOGIC.md`。
- **DL prune の clear 分岐がシャードキャッシュを invalidate しない（2026-06-07 受け入れテスト §6-2 で発見 → ✅ 修正済み 2026-06-07）**: DL 中断後に tmp が消えている（または stale）場合、旧挙動の `pruneOrphanTransfers` は `transfer_state` 行を削除するだけで `invalidateShardCache(forPath:)` を呼ばず → FileRecord 無し + `shard_state` は実 etag のまま → 当該ファイルはシャードがリモートで変化するまで**永久に再 DL されなかった**。**修正**: clear 分岐でも行を落とす**前に** invalidate を実行（resumable 分岐と対称）。invalidate 失敗時は行を消さずに continue（行が残れば次回起動の prune が再試行＝自己回復。先に行を消すと取り残しが再発するため順序が本質）。回帰テストのため prune 本体を `SyncEngine.pruneOrphanTransfers(db:store:syncRoot:now:abortUpload:)`（`nonisolated static`・依存注入）に切り出し、`TransferPruneTests`（実 DB + abort フェイク）で clear（tmp 消失/stale）・resumable・upload 全分岐の「分岐 → 実 I/O」配線を回帰固定（`security/low.md` L12 の「prune 結合テスト未整備」据え置きも同時解消）。**PR #11 レビュー反映**: `default:` 分岐（未知 direction・enum + DB CHECK の二重で到達不能）にも同じ「invalidate 先行・失敗なら行温存」ガードを適用して不変条件「download 行を落とす前に必ず invalidate」を全分岐化（Low-1。テストは `PRAGMA ignore_check_constraints` で破損 DB を模擬）、clear の成否どおりにログを出し分け（nit-2）。テスト追加で旧 `default:` 分岐の潜在欠陥も判明: `clearUpload`/`clearDownload` は direction フィルタ付きのため未知 direction 行にはマッチせず「安全側で除去」が実際には何も消せていなかった → `TransferStateStore.clearUnknownDirections(path:)` を新設して除去を実効化（同一 path の正当な upload/download 行は触らない）。
- **PR #11 レビューの据え置き（nit）**: 「invalidate 失敗 → 行温存」の自己回復経路がテスト未カバー（具象 `LocalDatabase` に失敗注入面が無い）。invalidate を `abortUpload` 同様のクロージャ注入にすれば固定できるが、注入面が増えるコストとの見合いで据え置き（PR #11 nit-4）。stale tmp は invalidate 恒久失敗時に残り続けるが「取り残し防止 > tmp litter」のトレードオフとして許容（nit-3・コード内コメントに明記）。
- **フルスキャンが同期済みファイルを毎起動再アップロードする（✅ 修正済み 2026-06-08）**: 原因は **mtime の精度不一致による自己持続サイクル**: ① Uploader は DB にサブ秒精度の stat mtime を格納、マニフェストは ISO8601 秒精度（fractional なし）。② すべての pull が全 entry を reconcile し、内容一致（`.localMatchesRemote`）でも `Downloader.download` の早期 return → `updateDBEntryWithoutWrite` が **DB mtime をマニフェスト由来の秒切捨て値で上書き**（`ManifestReader` は未変化シャードも DB から `ISO8601.format` で再合成するため**毎 pull 汚染**）。③ 次回起動スキャンの `< 0.001` 比較が外れ enqueue（docs/04 仕様の SHA ゲートが未実装だった）。④ 無条件アップロード → シャード etag 変化 → 次 pull で再汚染。**修正（2 層）**: (1) 根本 = `updateDBEntryWithoutWrite` がローカル stat 実値を記録（§7「mtime の不変条件と SHA ゲート」参照）。(2) 安全網 = docs/04 仕様の SHA ゲートを `ChangeDetector` + CAS で実装（汚染済み既存 DB も初回スキャンで自己修復）。回帰テストは `DownloaderTests`（早期 return の stat 記録・fail-first 確認済み）/ `ChangeDetectorTests` / `LocalDatabaseTests`（CAS）。
- **pull が毎回（最短 3 分毎）全ツリーを 2 回 hash + 全行 DB write する（据え置き・最適化）**: `performRemotePull` は remoteMap 全 entry（未変化シャードの DB 再合成分も含む）を `reconcileRemoteEntry` に通し、`ThreeWayMerge` 用と `download()` 早期 return 用に**毎 pull 全ファイルをハッシュ**する。正しさの問題ではないが定常コストが大きい。最適化形: reconcile 入口に stat ゲート（size/mtime == DB && DB.sha == entry.sha256 → スキップ）を入れる + `.localMatchesRemote` の `download()` 呼びを専用 `markSynced` に分離するリファクタ。`ChangeDetector` はこの第 3 の呼び元を見越した API にしてある（2026-06-08）。
- **ネスト `.syncignore`**: ディレクトリごとの `.syncignore`（git 風の階層的オーバーライド）は未対応。現状はルートの `<syncRoot>/.syncignore` のみ。将来タスク（`docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク B「既知の制限 / 将来タスク」参照）。
