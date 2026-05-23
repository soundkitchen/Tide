# Tide — AI エージェント向けガイド

このファイルは Claude Code / 互換エージェント (`AGENTS.md` と同一内容) が
セッション開始時に読み込む前提で書いてある。会話履歴や `docs/` の重要点、
これまでに確立した実装ルールを集約した。

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

- `Tide.xcodeproj/` は `xcodegen` が `project.yml` から **毎回生成する**。**直接編集しない**。`.gitignore` 済み。
- **Swift ファイルを追加 / 削除 / リネームしたら `make generate`** を踏まないと Xcode プロジェクトに反映されない。
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

## 7. 既知の据え置き項目

- **C3 後半**: HTTPS 強制バケットポリシー（`PutBucketPolicy` で `aws:SecureTransport=true`）。SDK 自体は HTTPS 既定で送るので緊急度は低い。
- **H3**: 静的 AWS キー → STS / IAM Identity Center への構造的置き換え。M3 以降で要検討。
- **M5**: アップロード時のハッシュ + 読み込みの TOCTOU。M3 のマルチパート対応で同時解消する。
- **L1**: App Sandbox 化。security-scoped bookmark + entitlement の正規対応は M3+。
- **L6**: `DebounceQueue.fire` の競合。`upload_queue.UNIQUE(path)` で実害は出ない想定。観察継続。
