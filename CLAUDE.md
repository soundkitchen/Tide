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
  - M3 双方向同期 / 競合解決 / マルチパート（未着手）
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
- `xcodebuild` を直接叩く時は **`-skipPackagePluginValidation -skipMacroValidation` が必須**（aws-sdk-swift が依存する smithy-swift のビルドプラグインの検証が CLI からは初回承認できないため）。Makefile はこれを内包している。
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
- **シンボリックリンクは絶対に追従しない**: `SyncEngine.performFullScan` の enumerator で `.isSymbolicLinkKey` を取り、symlink なら `skipDescendants()` + `continue`。Downloader の書き込み先がシンボリックリンクなら拒否。
- **新しい dotfile / 拡張子で「機密が紛れ込みそう」と思ったら、`HardcodedIgnoreRules` に即追加**。
- `PutObject` は常に `serverSideEncryption: .aes256` を指定。
- Keychain クエリは `kSecUseDataProtectionKeychain=true`, `kSecAttrAccessible=AfterFirstUnlock`, `kSecAttrSynchronizable=false` を必ず含める。
- `factoryReset` は Application Support / Caches / UserDefaults / Keychain を完全に消す（`make reset` と挙動を揃える）。

### SwiftUI 起き上がり
- **メニューバーポップオーバーから `openWindow(id:)` を呼ぶときは必ず `NSApp.activate(ignoringOtherApps: true)` を前置する**。LSUIElement = YES のアプリだとアプリがフォアグラウンドに来ておらず、ウィンドウが見えないまま開かれる事故が起きる。

### Time-of-check vs Time-of-use
- アップロード時のハッシュ計算と読み込みは現状別 syscall（M5、Deferred）。将来 M3 でストリーミング化する際に同一バッファ化する。

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
- **`AppleScript` でメニューバーポップオーバーをクリックする検証**は、`activate` 系で popover が dismiss しやすいので不安定。手動 UI 確認の方が早いことが多い。
- **GRDB の `MutablePersistableRecord.insert` は `didInsert` を実装しないと auto-increment id が反映されない**（`UploadQueueRecord` / `SyncLogRecord` で対応済み）。
- **Dropbox 配下にプロジェクトを置いている**ため、ビルド成果物 (`build/`) が Dropbox 同期に乗らないよう `.gitignore` および Dropbox 側で除外しておくのが望ましい。

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
- **ライフサイクルルールはマージ方式** (`TideS3Client.ensureLifecycleRules`)。`tide-` プレフィックスの ID で Tide 製ルールを識別し、ユーザ独自ルールは温存する。3 ID すべて揃っていれば PUT もスキップ。
- **`PutObject` は常に `serverSideEncryption: .aes256` を明示**。
- **プロビジョニング時に `enforcePublicAccessBlock()`** で 4 設定すべて true を投入。

### リセット / クリーンアップ
- **`AppEnvironment.factoryReset` は `make reset` と同じ振る舞いに揃える**: Application Support / Caches / UserDefaults / Keychain を全部消す。deviceId も含めて消す（`ConfigStore.resetIncludingDeviceId`）。

### ダウンロード一時ディレクトリ
- **`TideTmpDirectory.resolve(for:)` で同一ボリュームの tmp を返す**。第一選択は `~/Library/Caches/Tide/tmp/`。同期ルートと別ボリュームになる時のみ `<syncRoot>/.tide/tmp/` にフォールバック。`moveItem` の atomic 性を保つため。

### 競合ファイル命名
- **`ConflictNamer.localCopyRelativePath(for:at:)` の命名規則**: `<stem> (local copy YYYY-MM-DD HH-MM-SS).<ext>`。
  - 例: `note.txt` → `note (local copy 2026-05-24 12-34-56).txt`
  - 拡張子なしファイル / dotfile (`.gitignore` 等) も対応済み。

### リモート削除の取り扱い
- **「リモートで消えたファイルをローカル削除するのは、ローカルファイルの SHA が DB 記録（最後にアップロードした内容）と一致するときのみ」**。一致しなければユーザが触っているとみなし、`sync_log` に warning を残してスキップ。`Downloader.applyRemoteDeletion`。

### `xcodegen` / Xcode プロジェクト
- **`Tide.xcodeproj/` は git 追跡対象**。`make generate` 後の差分も同じコミットに含めるのがルール。
- xcuserdata は除外。

### `Localizable.xcstrings` の運用
- **新規キーには必ず `extractionState: "manual"`** を付ける（Xcode の自動 purge を防ぐため）。
- **「キーが既に登録されていないか」を編集前に `grep` で確認**（汎用語の重複事故が起きやすい — 過去に `"Region"` 重複で JSON が壊れた）。

### UI 起動・遷移
- **`MenuBarExtra(.window)` のポップオーバー内ボタンから `openWindow(id:)` を呼ぶときは、`NSApp.activate(ignoringOtherApps: true)` を必ず前置**。LSUIElement = YES のアプリだとアプリがフォアグラウンドに来ておらず、新しいウィンドウが obscured になる。

### Bootstrap 失敗時の挙動
- **`AppEnvironment.bootstrapFailure` に詳細理由（どのフィールド / Keychain 読みでコケたか）を入れる**。`MenuBarContent` はその値を見て自動的にセットアップウィザードを再表示する。

---

## 8. 既知の据え置き項目

- **C3 後半**: HTTPS 強制バケットポリシー（`PutBucketPolicy` で `aws:SecureTransport=true`）。SDK 自体は HTTPS 既定で送るので緊急度は低い。
- **H3**: 静的 AWS キー → STS / IAM Identity Center への構造的置き換え。M3 以降で要検討。
- **M5**: アップロード時のハッシュ + 読み込みの TOCTOU。M3 のマルチパート対応で同時解消する。
- **L1**: App Sandbox 化。security-scoped bookmark + entitlement の正規対応は M3+。
- **L6**: `DebounceQueue.fire` の競合。`upload_queue.UNIQUE(path)` で実害は出ない想定。観察継続。
