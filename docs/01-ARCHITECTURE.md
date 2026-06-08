# Tide アーキテクチャ（M1 + M2 実装後の現状）

> 当初は「M1 のみ」を対象に書かれたが、M2 の実装完了に伴って構成を更新した。
> M3 で追加されるコンポーネントは [`07-M3-IMPLEMENTATION-GUIDE.md`](07-M3-IMPLEMENTATION-GUIDE.md) を参照。

## モジュール構成

```
Tide/
├── Tide.xcodeproj                    xcodegen 生成（git 追跡対象、直接編集不可）
├── project.yml                       xcodegen の入力
├── Makefile                          build / test / reset / fresh の統合
├── Tide/
│   ├── App/
│   │   ├── TideApp.swift              @main、メニューバー常駐
│   │   └── AppEnvironment.swift       依存性注入コンテナ + factoryReset
│   ├── UI/
│   │   ├── MenuBarContent.swift       メニューバーのポップオーバー
│   │   ├── SettingsWindow.swift       設定画面
│   │   └── SetupWizardWindow.swift    初回セットアップ（リージョン Picker / バケット作成分岐）
│   ├── Core/
│   │   ├── SyncEngine.swift           同期制御の中枢（ローカル監視 + リモート pull）
│   │   ├── FileWatcher.swift          FSEvents ラッパー
│   │   ├── HashCalculator.swift       SHA-256 計算（ストリーミング）
│   │   ├── IgnoreRules.swift          ハードコード除外 + 既定の機密ファイル除外
│   │   ├── DebounceQueue.swift        変更イベントのデバウンス
│   │   ├── ConflictNamer.swift        コンフリクト時のリネーム命名 (M2)
│   │   ├── PathValidator.swift        リモート由来パス / シャード ID の検証 (security)
│   │   ├── TideTmpDirectory.swift     ダウンロード一時ディレクトリの解決 (M2)
│   │   ├── AppLogger.swift            os.Logger ラッパー
│   │   └── SyncError.swift            アプリ独自エラー型
│   ├── Storage/
│   │   ├── LocalDatabase.swift        GRDB.swift ラッパー
│   │   ├── KeychainStore.swift        認証情報保管（Data Protection Keychain）
│   │   ├── ConfigStore.swift          UserDefaults ラッパー
│   │   └── Migrations.swift           DB マイグレーション定義
│   ├── S3/
│   │   ├── S3Client.swift             AWS SDK ラッパー（SSE-S3 / PublicAccessBlock / ensureLifecycleRules マージ）
│   │   ├── Manifest.swift             マニフェスト型 + JSON 入出力
│   │   ├── ManifestSharding.swift     シャード振り分け（SHA-1 先頭バイト）
│   │   ├── ManifestReader.swift       リモート状態の集約読み込み (M2)
│   │   ├── Uploader.swift             アップロード処理 + ManifestUpdater
│   │   ├── Downloader.swift           ダウンロード + コンフリクトリネーム + 削除反映 (M2)
│   │   └── KnownRegions.swift         AWS リージョン一覧（Picker 用）
│   ├── Models/
│   │   ├── FileEntry.swift            マニフェストのファイルエントリ
│   │   ├── SyncEvent.swift            FileChangeEvent
│   │   ├── SyncStatus.swift           同期状態（idle, syncing, error 等）
│   │   └── AWSCredentials.swift       認証情報
│   └── Resources/
│       ├── Assets.xcassets
│       └── Localizable.xcstrings      String Catalog (en source / ja 翻訳)
└── TideTests/
    ├── ManifestShardingTests.swift
    ├── HardcodedIgnoreRulesTests.swift
    ├── HashCalculatorTests.swift
    ├── DebounceQueueTests.swift
    ├── ConflictNamerTests.swift
    ├── PathValidatorTests.swift
    └── SmokeTests.swift
```

「会話を通じて決まったが本書の上記表で説明しきれていない実装上の判断」は
プロジェクトルートの `CLAUDE.md` の「会話を通じて確定した実装決定」に集約している。

## レイヤー構成と依存方向

```
┌─────────────────────────────────────┐
│ UI Layer (SwiftUI)                  │
│  - MenuBarContent                   │
│  - SettingsWindow                   │
│  - SetupWizardWindow                │
└──────────────┬──────────────────────┘
               │ observes
               ▼
┌─────────────────────────────────────┐
│ Core Layer (Business Logic)         │
│  - SyncEngine                       │
│  - FileWatcher                      │
│  - HashCalculator                   │
└──────────────┬──────────────────────┘
               │ uses
               ▼
┌──────────────────┬──────────────────┐
│ Storage Layer    │ S3 Layer         │
│ - LocalDatabase  │ - S3Client       │
│ - KeychainStore  │ - Manifest       │
│ - ConfigStore    │ - Uploader       │
└──────────────────┴──────────────────┘
```

依存は常に下向き。UI → Core → Storage/S3。逆方向の依存は禁止。

## 主要コンポーネント

### SyncEngine（中枢）

責務:
- FileWatcher からの変更通知を受け取り、デバウンスして処理キューに積む
- アップロード処理を順次実行（並列度は5）
- 進捗・ステータスを `@Observable` で公開
- エラー時のリトライ管理（指数バックオフ、最大3回）

公開 API（M1 範囲）:
```swift
@Observable
final class SyncEngine {
    enum Status {
        case idle
        case syncing(progress: SyncProgress)
        case paused
        case error(SyncError)
    }
    
    var status: Status { get }
    var lastSyncedAt: Date? { get }
    var queueDepth: Int { get }
    
    func start() async
    func stop() async
    func pause()
    func resume()
    func triggerFullScan() async  // 起動時のフル比較
}
```

### FileWatcher

責務:
- 指定パス配下を FSEvents で監視
- 変更イベントを `AsyncStream<FileChangeEvent>` で配信
- ハードコード除外（`.DS_Store`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `Thumbs.db`）

公開 API:
```swift
struct FileChangeEvent {
    let path: String  // 同期ルートからの相対パス
    let kind: Kind
    enum Kind { case created, modified, deleted, renamed(from: String) }
}

final class FileWatcher {
    init(rootPath: URL)
    var events: AsyncStream<FileChangeEvent> { get }
    func start() throws
    func stop()
}
```

実装メモ:
- `FSEventStreamCreate` を使用
- `kFSEventStreamCreateFlagFileEvents` フラグを必ず付ける（ディレクトリ単位ではなくファイル単位の通知）
- `kFSEventStreamCreateFlagNoDefer` を付けてレイテンシ短縮
- latency 引数は 1.0 秒程度（FSEvents 自体のバッファリング）
- アプリ層でさらに 2 秒デバウンス（DebounceQueue）

### DebounceQueue

責務:
- 同じパスへの連続イベントを統合（例: エディタの保存で複数イベント発生）
- 最後のイベントから 2 秒静かになったら下流に流す

### HashCalculator

責務:
- ファイルの SHA-256 を計算
- 大きいファイルはストリーミング処理（メモリに全部載せない）
- 64KB チャンクで読み込み

```swift
struct HashCalculator {
    static func sha256(of url: URL) async throws -> String
}
```

### LocalDatabase

責務:
- ファイル状態のキャッシュ（再ハッシュ回避用）
- アップロード予約のキュー永続化
- 起動時の状態復元

スキーマは `03-LOCAL-DATABASE.md` 参照。

### S3Client

責務:
- AWS SDK for Swift のラッパー
- リトライ、エラーハンドリングの統一
- 認証情報の解決

公開 API（M1 範囲）:
```swift
final class S3Client {
    init(credentials: AWSCredentials, region: String, bucket: String)
    
    // Bucket
    func checkBucketAccess() async throws
    func isVersioningEnabled() async throws -> Bool
    func enableVersioning() async throws
    func setLifecycleRules() async throws
    
    // Objects
    func putObject(key: String, data: Data, metadata: [String: String]) async throws -> PutObjectResult
    func deleteObject(key: String) async throws  // delete marker を付ける
    func headObject(key: String) async throws -> HeadObjectResult?
    
    // Manifest
    func getIndex() async throws -> ManifestIndex?
    func putIndex(_ index: ManifestIndex, expectedETag: String?) async throws
    func getShard(_ id: String) async throws -> ManifestShard?
    func putShard(_ shard: ManifestShard, expectedETag: String?) async throws
}

struct PutObjectResult {
    let etag: String
    let versionId: String?
}
```

### Manifest

責務:
- マニフェストデータの読み書き、シャード分割
- 楽観的ロックによる更新（`If-Match` ヘッダ）

詳細は `02-S3-LAYOUT.md`。

## 起動フロー

```
[アプリ起動]
    │
    ▼
[ConfigStore で設定読み込み]
    │
    ├─ 設定がない（初回）
    │       │
    │       ▼
    │  [SetupWizard 表示]
    │       │
    │       ├─ AWS 認証情報入力
    │       ├─ バケット接続テスト
    │       ├─ バージョニング有効化（未有効なら）
    │       ├─ ライフサイクルルール投入
    │       ├─ 同期フォルダ選択
    │       └─ Device ID 生成
    │
    ├─ 設定あり
    │       │
    │       ▼
    │  [SyncEngine.start()]
    │       │
    │       ├─ FileWatcher 起動
    │       ├─ フルスキャン実行
    │       │   └─ ローカル DB と実ファイルを照合
    │       │       └─ 差分があればアップロードキューに積む
    │       └─ 通常運転（FSEvents からのイベント処理）
    │
    ▼
[メニューバーアイコン表示]
```

**bootstrap の起動契機（eager）**: 上記「設定あり → `SyncEngine.start()`」は **`@NSApplicationDelegateAdaptor` の `AppDelegate.applicationDidFinishLaunching` から eager に実行**する（`AppEnvironment` も `AppDelegate` が保持）。`MenuBarExtra(.window)` のポップオーバーコンテンツは初回オープン時に初めて生成されるため、bootstrap を `MenuBarContent.task` だけに置くと「メニューを開くまで同期/再開が始まらない」（ログイン自動起動後やアプリ再起動後に無同期になる）。`MenuBarContent.task` にも冪等な bootstrap 呼びを残し（未設定時のウィザード表示の保険）、`AppEnvironment.bootstrap()` は `engine != nil` と `isBootstrapping` で再入ガード済みなので 2 経路から呼ばれても二重起動しない。ただし **XCTest 実行中（`ProcessInfo.isRunningXCTests` = `XCTestConfigurationFilePath` の有無）は `bootstrap()` 冒頭で no-op で抜ける**。`make test` は本体アプリ（`Tide.app`）をテストホストとして起動し eager bootstrap が走るため、抑止しないとテストのたびに実 S3 と同期してしまう（実ユーザ向けの起動挙動は不変＝この抑止はテスト環境のみ）。テストで実 SyncEngine を駆動したい場合は `launchEngineFromCurrentConfig()` を直接呼ぶ。

## 同期処理フロー（M1: 一方向）

```
[FSEvents イベント発生]
    │
    ▼
[FileWatcher が AsyncStream に流す]
    │
    ▼
[DebounceQueue で 2 秒デバウンス]
    │
    ▼
[SyncEngine がイベントを受け取る]
    │
    ▼
[除外ルール判定]
    │
    ├─ 除外対象 → 終了
    │
    ▼
[ローカル DB から前回情報を取得]
    │
    ▼
[変更タイプ別処理]
    │
    ├─ created / modified
    │     │
    │     ▼
    │   [ファイルサイズ・mtime チェック]
    │     │
    │     ▼
    │   [DB のキャッシュと size+mtime が一致？]
    │     │
    │     ├─ Yes → アップロード不要（イベント空振り）
    │     └─ No  → SHA-256 計算
    │             │
    │             ▼
    │           [DB の前回ハッシュと比較]
    │             │
    │             ├─ 一致 → DB の mtime 更新のみ
    │             └─ 不一致 → アップロードキューに追加
    │
    └─ deleted
          │
          ▼
        [DeleteObject 呼び出し]
          │
          ▼
        [マニフェスト更新]
          │
          ▼
        [DB のエントリ削除]
    │
    ▼
[アップロード実行（並列度 5）]
    │
    ├─ PutObject（メタデータ付き）
    ├─ DB 更新（version_id, etag, last_synced_at）
    └─ マニフェスト更新（シャード + index）
```

## エラーハンドリング方針

- **ネットワークエラー**: 指数バックオフで自動リトライ（1s, 2s, 4s, 8s, 16s）。最大5回。それでもダメなら error 状態へ。
- **認証エラー**: 即座にユーザーに通知。リトライしない。設定画面を開いてもらう。
- **権限エラー（S3）**: ユーザーに通知。リトライしない。
- **ハッシュ計算中にファイル削除**: 警告ログを出して次のイベントを待つ。
- **マニフェスト更新の楽観的ロック失敗**: 5回までリトライ（その都度マニフェスト再読み込み）。
- **ローカル DB エラー**: クリティカル。アプリ停止して通知。

## ログ出力

- `os.Logger` を使用
- サブシステム: `com.example.tide`
- カテゴリ: `sync`, `s3`, `database`, `ui`
- レベル: debug / info / error
- リリースビルドでも error は残す
