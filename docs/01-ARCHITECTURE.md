# Tide アーキテクチャ（M1〜M4 実装後の現状）

> 当初は「M1 のみ」を対象に書かれたが、M2〜M4 の実装完了に伴って構成を更新した。
> 本書の API シグネチャの一部は M1 当時のスケッチが残っている箇所がある（その旨を各所に注記）。
> M3 で追加されたコンポーネントの設計詳細は [`07-M3-IMPLEMENTATION-GUIDE.md`](07-M3-IMPLEMENTATION-GUIDE.md)、
> 確定した実装判断は [`08-IMPLEMENTATION-NOTES.md`](08-IMPLEMENTATION-NOTES.md) を参照。
>
> **M5（Files-On-Demand・着手中）による読み替え**: M5 Phase 1 で 3 ターゲット構成へ移行した —
> `TideCore/`（framework。下記ツリーの `Tide/{S3,Storage,Models}/` 全部と `Tide/Core/` の純粋型を収容・
> `APPLICATION_EXTENSION_API_ONLY=YES`）+ `Tide/`（app。`SyncEngine` 等の駆動層/殻と UI が残る）+
> `TideFileProvider/`（File Provider 拡張 `.appex`。`FileProviderExtension` / `FileProviderEnumerator` /
> `FileProviderItem` / `ExtensionServices` / `ExtensionWriter`。TideCore に依存・DB 非接触）。
> **ファイル名・型名は不変**なので下記ツリーの個別書き換えはしていない（読み替え規則は
> `CLAUDE.md` §6、拡張側の設計は `08`「FP 双方向書込」ほか M5 各節と `09-DEFERRED.md` M5 節を参照）。

## モジュール構成

```
Tide/
├── Tide.xcodeproj                    xcodegen 生成（git 追跡対象、直接編集不可）
├── project.yml                       xcodegen の入力
├── Makefile                          build / test / reset / fresh の統合
├── Tide/
│   ├── App/
│   │   ├── TideApp.swift              @main、メニューバー常駐（NSApplicationDelegateAdaptor で eager bootstrap）
│   │   ├── AppEnvironment.swift       依存性注入コンテナ + factoryReset
│   │   └── NotificationManager.swift  UserNotifications 配信（@MainActor・初回発火時に許可要求）(M4)
│   ├── UI/
│   │   ├── MenuBarContent.swift       メニューバーのポップオーバー
│   │   ├── MenuBarPresentation.swift  ポップオーバー表示ロジック（headline / issue グルーピング）(M4)
│   │   ├── SettingsWindow.swift       設定画面（帯域上限 / 通知トグル / .syncignore 閲覧）
│   │   ├── SetupWizardWindow.swift    初回セットアップ（リージョン Picker / バケット作成分岐）
│   │   ├── VersionHistoryWindow.swift 過去バージョン / 削除済み復元ウィンドウ (M4)
│   │   ├── VersionHistoryModel.swift  ↑の @MainActor @Observable モデル
│   │   ├── SyncActivityWindow.swift   同期アクティビティ（sync_log 閲覧）ウィンドウ (M4)
│   │   ├── SyncActivityModel.swift    ↑の @MainActor @Observable モデル（フィルタ / ページング）
│   │   ├── AboutWindow.swift          バージョン情報ウィンドウ（PR #24）
│   │   └── UIHelpers.swift            UI 共通ヘルパー
│   ├── Core/
│   │   ├── SyncEngine.swift           同期制御の中枢（@MainActor @Observable・ローカル監視 + リモート pull）
│   │   ├── FileWatcher.swift          FSEvents ラッパー
│   │   ├── HashCalculator.swift       SHA-256 計算（ストリーミング）
│   │   ├── ChangeDetector.swift       stat ベースの差分判定（preDecision / reconcileIsNoop）(M4)
│   │   ├── ThreeWayMerge.swift        3-way merge 判定（decide / decideUpload）(M3)
│   │   ├── IgnoreRules.swift          ハードコード除外 + 既定の機密ファイル除外
│   │   ├── IgnoreDecision.swift       除外判定の統合（scan/event/reconcile 共用）(M3)
│   │   ├── SyncIgnoreMatcher.swift    .syncignore パターンマッチ（線形時間 DP）(M3)
│   │   ├── DebounceQueue.swift        変更イベントのデバウンス
│   │   ├── RateLimiter.swift          帯域制御（トークンバケット）(M3)
│   │   ├── StabilityCheck.swift       torn upload 検出（読了後の再 stat）(M3)
│   │   ├── NoFollowFileReader.swift   O_NOFOLLOW 単一 FD 読み出し（TOCTOU 解消）(M3)
│   │   ├── RestoreService.swift       過去バージョン / 削除済みの復元 (M4)
│   │   ├── ConflictNamer.swift        コンフリクト時のリネーム命名 (M2)
│   │   ├── PathValidator.swift        リモート由来パス / シャード ID の検証 (security)
│   │   ├── TideTmpDirectory.swift     ダウンロード一時ディレクトリの解決 (M2)
│   │   ├── DiagnosticsExporter.swift  診断情報エクスポート（PR #24）
│   │   ├── NotificationPolicy.swift   通知発火判定（純粋関数・4 事象のみ）(M4)
│   │   ├── AppLogger.swift            os.Logger ラッパー
│   │   ├── SyncError.swift            アプリ独自エラー型
│   │   └── SyncIssueClassifier.swift  エラー → SyncIssue 分類（純粋関数・F4/H2 対応）(M4)
│   ├── Storage/
│   │   ├── LocalDatabase.swift        GRDB.swift ラッパー
│   │   ├── KeychainStore.swift        認証情報保管（Data Protection Keychain）
│   │   ├── ConfigStore.swift          UserDefaults ラッパー
│   │   ├── TransferStateStore.swift   中断・再開の転送状態永続化（transfer_state）(M3)
│   │   └── Migrations.swift           DB マイグレーション定義
│   ├── S3/
│   │   ├── S3Client.swift             AWS SDK ラッパー（SSE-S3 / PublicAccessBlock / ensureLifecycleRules マージ）
│   │   ├── BucketPolicyBuilder.swift  HTTPS 強制バケットポリシー生成（C3）
│   │   ├── Manifest.swift             マニフェスト型 + JSON 入出力
│   │   ├── ManifestSharding.swift     シャード振り分け（SHA-1 先頭バイト）
│   │   ├── ManifestReader.swift       リモート状態の集約読み込み (M2)
│   │   ├── Uploader.swift             アップロード処理 + ManifestUpdater
│   │   ├── MultipartUploader.swift    マルチパートアップロード（自前ラッパ）(M3)
│   │   ├── PartPlan.swift             マルチパートのパート分割計画 (M3)
│   │   ├── Downloader.swift           ダウンロード + コンフリクトリネーム + 削除反映 (M2)
│   │   ├── ObjectVersionHistory.swift バージョン一覧 / 削除済み列挙 (M4)
│   │   └── KnownRegions.swift         AWS リージョン一覧（Picker 用）
│   ├── Models/
│   │   ├── FileEntry.swift            マニフェストのファイルエントリ（型名は ManifestFileEntry）
│   │   ├── SyncEvent.swift            ファイル変更イベント（型名は FileChangeEvent）
│   │   ├── SyncStatus.swift           同期状態（notConfigured, idle, syncing, paused, error 等）
│   │   ├── TransferProgress.swift     転送進捗 (M3)
│   │   ├── SyncIssue.swift            UI 向けの構造化エラー（分類サマリ + rawDetail 隔離）(M4)
│   │   └── AWSCredentials.swift       認証情報
│   └── Resources/
│       ├── Assets.xcassets
│       └── Localizable.xcstrings      String Catalog (en source / ja 翻訳)
└── TideTests/                          （主要なもの。全テストは TideTests/ 配下を参照）
    ├── ManifestShardingTests.swift
    ├── HardcodedIgnoreRulesTests.swift
    ├── HashCalculatorTests.swift
    ├── DebounceQueueTests.swift
    ├── ConflictNamerTests.swift
    ├── PathValidatorTests.swift
    ├── ThreeWayMergeTests.swift
    ├── SyncIgnoreMatcherTests.swift
    ├── TransferPruneTests.swift
    ├── UploaderConflictTests.swift
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

公開 API（現状。M2 以降で pull 系を追加）:
```swift
// 状態は別ファイル Models/SyncStatus.swift の独立 enum
enum SyncStatus: Equatable, Sendable {
    case notConfigured
    case idle
    case syncing(SyncProgress)
    case paused
    case error(String)   // 連想値は SyncError ではなく表示用 String
}

@MainActor
@Observable
final class SyncEngine {
    var status: SyncStatus = .notConfigured
    var lastSyncedAt: Date?
    var queueDepth: Int = 0

    func start() async
    func stop() async
    func pause()
    func resume()
    func triggerFullScan() async                           // 起動時 / 明示のフル比較
    func triggerRemotePull(reason: PullReason = .manual) async  // リモート pull（単一ゲートで直列化）
}
```

### FileWatcher

責務:
- 指定パス配下を FSEvents で監視
- 変更イベントを `AsyncStream<FileChangeEvent>` で配信
- ハードコード除外（`.DS_Store`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `Thumbs.db`）

公開 API（型定義は Models/SyncEvent.swift）:
```swift
struct FileChangeEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case createdOrModified   // created / modified は統合（rename も create+delete 相当で扱う）
        case deleted
    }
    let relativePath: String     // 同期ルートからの POSIX 相対パス
    let kind: Kind
}

final class FileWatcher {
    init(rootURL: URL)
    let events: AsyncStream<FileChangeEvent>
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
    static func sha256(of url: URL, chunkSize: Int = 65_536) throws -> String
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

公開 API（現状の主要メソッド。M2〜M4 で拡張済み。ファイル名は `S3Client.swift` だが実型名は `TideS3Client`）:
```swift
final class TideS3Client: @unchecked Sendable {
    init(credentials: AWSCredentials, region: String, bucket: String, deviceId: String) throws

    // Bucket
    func checkBucketAccess() async throws
    func isVersioningEnabled() async throws -> Bool
    func enableVersioning() async throws
    func enforcePublicAccessBlock() async throws
    func enforceTLSBucketPolicy() async throws -> TLSPolicyStatus     // HTTPS 強制（C3）
    func ensureLifecycleRules() async throws -> LifecycleStatus       // tide-* ルールをマージ

    // Objects
    func putObject(key: String, data: Data, contentType: String = "application/octet-stream",
                   metadata: [String: String] = [:],
                   ifMatch: String? = nil, ifNoneMatch: String? = nil) async throws -> PutObjectResult
    func deleteObject(key: String) async throws                      // delete marker を付ける
    func headObject(key: String, versionId: String? = nil) async throws -> ObjectHead?
    func getObject(key: String, maxBytes: Int64 = 200 * 1024 * 1024, versionId: String? = nil) async throws -> ObjectFetch?
    func listObjectVersions(...) async throws -> ObjectVersionPage    // M4 バージョン履歴

    // Manifest（楽観的ロックは ifMatch / ifNoneMatch。戻り値は新 ETag）
    func getIndex() async throws -> ManifestFetch<ManifestIndex>?
    func putIndex(_ index: ManifestIndex, ifMatch: String?) async throws -> String
    func getShard(_ id: String) async throws -> ManifestFetch<ManifestShard>?
    func putShard(_ shard: ManifestShard, ifMatch: String?) async throws -> String
    func deleteShard(_ id: String) async throws
}

struct PutObjectResult {
    let etag: String
    let versionId: String?
}
```

> マルチパート（`createMultipartUpload` / `uploadPart` / `completeMultipartUpload` /
> `abortMultipartUpload`）とストリーミング DL（`streamObject`）は M3 で追加。詳細は
> [`07-M3-IMPLEMENTATION-GUIDE.md`](07-M3-IMPLEMENTATION-GUIDE.md) を参照。

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
    │       ├─ File Provider ドメイン有効化（v0.3.0 #97。旧「同期フォルダ選択」は廃止）
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
- サブシステム: `org.izukawa.Tide`
- カテゴリ: `sync`, `s3`, `database`, `ui`, `watcher`, `fileprovider`（File Provider 拡張・M5 Phase 3〜）
- レベル: debug / info / error
- リリースビルドでも error は残す
