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
- **アーキテクチャ**: macOS 26+ 専用、Swift 6（strict concurrency: complete）、SwiftUI、メニューバー常駐 (`LSUIElement = YES`)、App Sandbox 有効（M5 Phase 2〜。同期フォルダは security-scoped bookmark でアクセス）。
- **設計の原典**: `docs/00-OVERVIEW.md` から `docs/06-SETUP-AND-BUILD.md` まで。**仕様に迷ったら先に docs/ を読むこと。**
- **マイルストーン**: 
  - M1 ローカル → S3 一方向アップロード（実装済み）
  - M2 ダウンロード / 復元 / ポーリング（実装済み・MVP ゴール）
  - M3 双方向同期 / 競合解決 / マルチパート（サブ A〜E 実装済み: マルチパート / `.syncignore` / 3-way merge / 中断・再開 / 帯域制御。**M3 完了**。`docs/09` の据え置き数件あり）
  - M4 運用機能と磨き込み（復元/バージョン UI・Sync Activity/エラー履歴・通知・pull コスト削減。**M4 完了**。詳細は `docs/00-OVERVIEW.md` と `docs/08-IMPLEMENTATION-NOTES.md`）
  - M5 Files-On-Demand（File Provider）— オンラインのみ実体化: **着手中**。Phase 1（`TideCore` framework 分離）・Phase 2（App Group 移設 + App Sandbox 化 + security-scoped bookmark）完了。次は Phase 3（`TideFileProvider.appex` の読み取り materialize PoC）。同期先は最終的に `~/Library/CloudStorage/Tide` 固定（既存 FSEvents の任意フォルダモードと opt-in 並走）。設計・進捗は `docs/09-DEFERRED.md` の M5 節

### 主要な確定パラメータ
- Bundle ID: `org.izukawa.Tide`
- DEVELOPMENT_TEAM: `G5G54TCH8W`
- App Group: `group.org.izukawa.Tide`（M5 Phase 2〜。定数は `TideAppGroup`）
- ローカル DB: `~/Library/Group Containers/group.org.izukawa.Tide/Library/Application Support/Tide/db.sqlite`（GRDB.swift / WAL。M5 Phase 2 で App Group コンテナへ移設。旧パスからは `LegacyStateMigrator` が一度きり移行）
- 設定: group suite の UserDefaults（`TideAppGroup.sharedDefaults()`）。Keychain は `kSecAttrAccessGroup` 明示（`$(AppIdentifierPrefix)org.izukawa.Tide`）
- 同期フォルダのアクセス権: `ConfigStore.syncRootBookmark`（security-scoped bookmark。セットアップ時発行 → 起動時 `resolveSyncRootAccess` で解決。リネーム/移動は bookmark が追跡し `syncRootPath` を追随更新。欠落時は再許可パネル・設定と**同一実体でない**フォルダは拒否＝判定は `PathValidator.isSameFileSystemObject`）
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
- **ファイルに書き出す export 系（`DiagnosticsExporter` / `SettingsTransfer`）には AWS 認証情報・`deviceId` を絶対に入れない**。`SettingsTransfer.Payload` は非機密設定のみ（フィールドが無く構造的に漏れない）＝フィールド追加時に機密を足さない。認証情報は Data Protection Keychain のみ。`security/low.md` L13/L14。
- `factoryReset` は**アプリから届く範囲で** `make reset` に揃える: App Group コンテナ（DB）/ コンテナ内 Caches / UserDefaults（group + standard）/ Keychain を消す。sandbox 下では実ホームの旧ロケーション残置分（pre-sandbox の db.sqlite / Caches）に届かない — 完全削除は `make reset`（sandbox 外）のみ。→ `docs/08`

### SwiftUI 起き上がり
- **メニューバーポップオーバーから `openWindow(id:)` を呼ぶときは必ず `NSApp.activate(ignoringOtherApps: true)` を前置する**。LSUIElement = YES のアプリだとアプリがフォアグラウンドに来ておらず、ウィンドウが見えないまま開かれる事故が起きる。
- **`MenuBarExtra` のラベル（status item アイコン）に `TimelineView(.animation)` を置いてはならない**。その文脈では `minimumInterval` が無視され、SwiftUI が `MenuBarExtraHost.requestUpdate(after:)` を実質ゼロ間隔で再発火し続ける。毎回 `NSStatusItem` の画像差し替え（`setImage:` → `_adjustLength` → Auto Layout 再計算）が走り、**メインスレッドが 100% スピンしてアプリ全体が無応答（＝ハング）になる**（2026-06-18、同期中アニメで実機再現・サンプル採取で確定）。アイコンのコマ送りアニメが要るときは、`.task(id:)` 内の自前タイマー（`Task.sleep`）で `@State` のフレーム番号を進め、`Image("…\(frame)")` を差し替える方式にする。`.task(id:)` のキー（例: `isSyncing`）が落ちている間はタイマーが回らず CPU を消費しない。実装は `Tide/App/TideApp.swift` の `MenuBarLabel` 参照。

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
| `TideCore/`（framework） | **app と File Provider 拡張が共有する同期コア**（M5 Phase 1 で分離）。下記 S3/Storage/Models と Core 純粋型を収容。`APPLICATION_EXTENSION_API_ONLY=YES`（拡張安全 API のみ）|
| `TideCore/S3/` | S3Client / Uploader / Downloader / ManifestReader / KnownRegions |
| `TideCore/Storage/` | GRDB DB / KeychainStore / ConfigStore / Migrations |
| `TideCore/Models/` | 構造体（AWSCredentials / SyncStatus 等） |
| `TideCore/Core/` | 純粋 Core（MainActor 非依存）: ThreeWayMerge / ChangeDetector / PathValidator / HashCalculator / RateLimiter / RestoreService / IgnoreDecision / IgnoreRules / SyncIgnoreMatcher / ConflictNamer / StabilityCheck / NoFollowFileReader / SyncError / SyncIssueClassifier / DeletedFilesCache / TideTmpDirectory / AppLogger |
| `Tide/App/` | エントリポイント / `AppEnvironment` |
| `Tide/UI/` | SwiftUI ビュー（MenuBar / Setup wizard / Settings） |
| `Tide/Core/` | **app-bound な駆動層/殻**（TideCore に移さず残す）: SyncEngine / RemoteOpGate / FileWatcher / DebounceQueue / DiagnosticsExporter / NotificationPolicy / SettingsTransfer |
| `Tide/Resources/` | `Localizable.xcstrings` / アセット |
| `TideTests/` | ユニットテスト |
| `docs/` | 設計書（spec）。`00`〜`07` が仕様、`08-IMPLEMENTATION-NOTES.md` が実装ノート（旧 §7）、`09-DEFERRED.md` が据え置き/バックログ（旧 §8） |
| `security/` | セキュリティレビューと対応サマリ |
| `tmp/` | 動作チェックリスト等の使い捨て（`.gitignore` 済み） |

> **docs パス参照の読み替え（M5 Phase 1 以降）**: `docs/*` や本ファイル内に残る旧 `Tide/S3|Storage|Models/…` と、Core 純粋型（`ThreeWayMerge`/`ChangeDetector`/`PathValidator`/`HashCalculator`/`RateLimiter`/`RestoreService`/`IgnoreDecision`/`IgnoreRules`/`SyncIgnoreMatcher`/`ConflictNamer`/`StabilityCheck`/`NoFollowFileReader`/`SyncError`/`SyncIssueClassifier`/`DeletedFilesCache`/`TideTmpDirectory`/`AppLogger`）のパスは、物理的には `TideCore/…` 配下へ移設済み（**ファイル名・型名は不変**なので個別の書き換えはしていない）。`SyncEngine`/`RemoteOpGate`/`FileWatcher`/`DebounceQueue`/`DiagnosticsExporter`/`NotificationPolicy`/`SettingsTransfer` は駆動層/殻として `Tide/Core/` に残る。

---

## 7. 実装上の不変条件（詳細は `docs/08-IMPLEMENTATION-NOTES.md`）

会話で確定した実装の詳細な決定経緯は **`docs/08-IMPLEMENTATION-NOTES.md`** に集約した。
ここには毎回守るべき **load-bearing な不変条件**の要約だけを置く（破ると無エラー乖離 / データ損失 /
毎起動再アップロード等の事故になる）。理由・経緯・テスト名は docs/08 と該当 `docs/0X` を参照。
§3 のセキュリティゲート/規約と併せて必読。

- **[pull/restore 直列化]** すべてのリモート pull と復元（`SyncEngine.restore`）は単一ゲート `RemoteOpGate`（`@MainActor` 非再入 async ロック）を通す。pull は `tryAcquire`（busy ならドロップ／手動は pending）、restore は `acquire`（FIFO 待機）。並行 pull は共有 tmp `dl-<sha>.part` を破壊し、復元の atomic move と pull の reconcile/削除反映が同一 path に同時に触れると壊れる。`isRemotePulling` は UI 表示専用に残す（#34 / D5）。→ `docs/04` / `docs/08`
- **[DL サイズ検証]** `Downloader.download` は commit（tmp→本体 move）前に「実 tmp サイズ == `entry.size`」を検証する。
- **[reconcile ゲート]** pull 取り込みは入口で純粋関数 `ChangeDetector.reconcileIsNoop` を通し、no-op（ローカル==DB==リモート）を skip（hash も DB write もしない）。→ `docs/04`
- **[リモート削除反映]** `Downloader.applyRemoteDeletion` は `ThreeWayMerge.decide(remote:nil)` で削除可否を決める＝`.deleteLocal`（base==local＝未編集）のみ実削除、編集済み/未追跡/unreadable は `.keepLocalRemoteDeleted` で**温存**（無条件削除はリモート削除でローカル編集を消す＝他端末由来のデータ損失）。symlink は削除せず、ローカル不在は孤児 `FileRecord` のみ掃除。判定→I/O の配線は `RemoteDeletionTests` で固定（#30 / D1）。→ `docs/08` / `docs/09`
- **[prune 順序]** 中断転送の prune は download 行を落とす**前に**必ず `invalidateShardCache(forPath:)` を実行する（逆順だと中断 DL がシャード変化まで永久に再 DL されず＝クリーンインストール復旧で一部ファイル欠落）。→ `docs/09`
- **[mtime 不変条件]** `FileRecord.mtime` = 最後に同期した時点の**ローカル stat 実値**。マニフェスト ISO8601 秒精度値で上書きしない（毎起動再アップロードの自己持続サイクルになる）。`Downloader.markSynced` も stat 実値を記録。**マニフェスト mtime に fractional seconds を足さない**（`parseISO8601` が nil → now フォールバックでパース全滅）。
- **[キュー行 id 基準]** アップロードキュー行の完了/失敗処理は **`item.id` 基準**で消す（`path` 基準にしない）。処理中に置換された新 id 行を巻き込むと無エラー乖離になる。
- **[torn 安定化ゲート]** アップロードは読了後に同 FD を再 `fstat` し、size 変化 or mtime 前進があれば torn とみなして commit しない（`StabilityCheck` / `SyncError.fileChangedDuringUpload`）。不安定ファイルは give-up させず延期＋1 回可視化。
- **[アップロード競合検出]** アップロードのマニフェスト書込は `Uploader.ManifestUpdater.updateFileEntry` で権威シャードの現 entry を読み `ThreeWayMerge.decideUpload` で判定する（無条件上書きしない）。`.conflict` は `SyncError.uploadConflict` を投げて RMW を安全中断＝**412/409 クラシファイアにマッチさせない**（リトライに飲ませない）。解決は pull 側 `.conflictThenDownload` と対称（リモート版が正規パスで勝つ）。Issue #25 / A。→ `docs/04` / `docs/08`
- **[アップロード競合：リネーム≦キュー行除去]** `SyncEngine.resolveUploadConflict` は「**item.id 基準で行除去 → 成功時のみ** `renameLocalForConflict`」の順。canonical 消失とキュー行残存を同時に作らない（さもないと再処理が `convertQueueItemToDelete` → リモート delete-marker＝他端末データ損失）。失敗は次回 pull で自己回復。
- **[アップロード競合：リモート版は versionId 取得]** 解決の取得は `Downloader.download(versionId: remoteEntry.s3VersionId, clearQueueByPath: false)`。本体 PUT が「最新」を自分の内容に変えているため最新取得では相手版を取れず sha 検証に失敗する。`clearQueueByPath:false` で同 path の新 id 行を巻き込まない（[キュー行 id 基準] の維持）。
- **[stale UploadId]** マルチパート再開で死んだ UploadId（前回 complete 済み→`clearUpload` 前にクラッシュ／7 日失効）は `NoSuchUpload` で空振りする。complete 時の `NoSuchUpload` は `headObject(key:)` で本体を確認し**存在 & `head.size == bytesRead` 一致なら identity 回収で成功扱い**（checkpoint クリア）。回収不能、および `uploadPart` 時の `NoSuchUpload`（失効 MPU）は **checkpoint を破棄してフル再開に委ねる**（保持すると死んだ UploadId を毎周回再開し続け、そのファイルが永久に上がらない）。`isNoSuchUpload` は `NoSuchUpload` 文字列で明示判定（HTTP 404 なので一般 404 と取り違えない）。→ Issue #33 / `docs/04` / `docs/08`
- **[ignore 優先順位]** ハードコード除外（機密網）が常に最優先。ユーザ `.syncignore` パターンは**未追跡ファイルのみ**に適用。`.syncignore` 自身（ルート/ネスト両方＝末尾 `/.syncignore`・判定は `IgnoreDecision.isSyncignoreFile`）は決して除外しない。判定は `IgnoreDecision.shouldSkip`（scan/event/reconcile の 3 経路共用）。
- **[ネスト .syncignore]** ディレクトリごとの `.syncignore` を git 風に階層適用（[#27] / C1）。`shouldSkip` の `matcher` は `LayeredSyncIgnore`（dir→`SyncIgnoreMatcher` 辞書）で、祖先 dir を**浅い→深い順**に合成し深い層が浅い層を上書きする（`SyncIgnoreMatcher.evaluate` は三状態）。**キャッシュは「変更時フル再構築」**: dir→matcher 辞書がキャッシュ本体で評価経路は I/O ゼロ。辞書再構築（`loadLayeredIgnore` のツリー走査）は起動時と実際の `.syncignore` 変更時のみ（ローカルは FSEvents、リモートは pull が `.syncignore` を触ったときだけ。定常 pull では再走査しない）。走査は symlink 非追従・機密網 dir 丸ごとスキップ・`maxFiles` で有界。→ `docs/07` サブタスク B / `docs/08`
- **[競合/復元コピー名]** `ConflictNamer` の命名は**時系列ソート可能書式**（`Date.VerbatimFormatStyle`・`YYYY-MM-DD HH-MM-SS`）。ロケール依存書式（`.dateTime` 等）にしない（辞書順が時系列にならない）。
- **[エラー表示]** UI に見せるエラーは構造化型 `SyncIssue` に一本化し、生エラー文字列は `rawDetail` に隔離（オンデマンド参照のみ）。`sync_log.event_type` はリテラル禁止＝`SyncLogEventType` の rawValue。DB 内の path/message/details は英語生文字列なので UI では **`Text(verbatim:)`**。
- **[bootstrap eager]** bootstrap は `AppDelegate.applicationDidFinishLaunching` から eager 実行（`MenuBarContent.task` は未設定時ウィザードの保険）。再入は `engine != nil` / `isBootstrapping` でガード。
- **[通知の発火条件]** 通知は「ユーザ介入が要る/取りこぼし確定」の 4 事象だけ（競合コピー / `fileTooLarge` / give-up / 不安定）。一過性エラーは出さない。配線は fire-and-forget。

> S3/バケット運用・マルチパート・帯域制御・復元 UI・Sync Activity・ポップオーバー構成・通知の実装詳細など、
> 上記以外の運用決定はすべて `docs/08-IMPLEMENTATION-NOTES.md` を参照。新しい実装決定もそちらへ追記する。

---

## 8. 既知の据え置き項目 / バックログ

未対応の将来タスク・解消済み項目の記録は **`docs/09-DEFERRED.md`** に集約した。
新しい据え置き・解消はそちらに追記する（CLAUDE.md には残さない）。
