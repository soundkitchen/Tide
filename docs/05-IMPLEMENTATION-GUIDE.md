# Claude Code 向け実装ガイド（M1 — 完了済み・参考用）

> **このドキュメントは過去ログ扱い**: M1 はステップ 1〜12 まで完了済み。
> 現状のアーキテクチャは `01-ARCHITECTURE.md`、現状の同期ロジックは `04-SYNC-LOGIC.md` を参照。
> M3 着手前の設計メモは `07-M3-IMPLEMENTATION-GUIDE.md`。

このドキュメントは、Claude Code が M1 を実装するための手順書。

## 前提

- macOS 26+ のマシン
- Xcode 17+ がインストール済み
- 開発者は AWS アカウントを持っており、テスト用 S3 バケットを用意できる

## 実装順序

以下の順で実装すること。各ステップ完了時にビルドが通り、可能ならユニットテストも通る状態を維持する。

### ステップ1: プロジェクト初期化

1. `Tide.xcodeproj` を Xcode で作成
   - Template: macOS > App
   - Interface: SwiftUI
   - Language: Swift
   - Minimum Deployment: macOS 26.0
   - App lifecycle はデフォルト（SwiftUI）

2. Package Dependencies を追加（Project > Package Dependencies）:
   - `https://github.com/awslabs/aws-sdk-swift` → 最新の安定版
     - 必要モジュール: `AWSS3`, `AWSClientRuntime`
   - `https://github.com/groue/GRDB.swift` → 最新の安定版

3. App Sandbox を一時的にオフにする（M1 では）
   - Signing & Capabilities > App Sandbox を削除
   - 理由: 任意のフォルダを監視する必要があり、サンドボックス制約と相性が悪い
   - 本格的な配布時は適切な権限設定で再有効化

4. メニューバーアプリ化:
   - `Info.plist` に `LSUIElement = YES` を追加（Dock アイコン非表示）

### ステップ2: 基本構造の作成

`01-ARCHITECTURE.md` のディレクトリ構造に従って、空ファイルを全部作る。各ファイルは最低限の `import` と空の `struct`/`class` 定義だけでよい。これで以降の実装で循環参照を避けやすくなる。

### ステップ3: Models 層

優先度高:
1. `Models/AWSCredentials.swift`: アクセスキー・シークレットを保持する struct
2. `Models/FileEntry.swift`: マニフェストおよび DB のファイルエントリ
3. `Models/SyncStatus.swift`: 同期状態 enum
4. `Models/SyncEvent.swift`: 内部イベント

### ステップ4: Storage 層

1. `Storage/ConfigStore.swift`:
   - UserDefaults ラッパ
   - 保存項目: bucketName, region, syncRootPath, deviceId, pollingIntervalSeconds
   - deviceId は初回アクセス時に自動生成（UUID）

2. `Storage/KeychainStore.swift`:
   - Security framework 直接使用
   - サービス名: `org.izukawa.Tide`
   - アカウント: `aws_access_key_id`, `aws_secret_access_key`
   - メソッド: `save(credentials:)`, `load() throws -> AWSCredentials?`, `delete()`

3. `Storage/Migrations.swift`:
   - `03-LOCAL-DATABASE.md` のスキーマ定義
   - GRDB の `DatabaseMigrator` を構築する関数を export

4. `Storage/LocalDatabase.swift`:
   - GRDB の `DatabasePool` ラッパ
   - シングルトンではなく依存性注入できる形にする
   - WAL モード設定

### ステップ5: S3 層（基礎）

1. `S3/S3Client.swift`:
   - AWS SDK for Swift の `S3Client` をラップ
   - 初期化時に認証情報・リージョン・バケットを受け取る
   - `checkBucketAccess()`: `HeadBucket` で疎通確認
   - `isVersioningEnabled() -> Bool`
   - `enableVersioning()`
   - `setLifecycleRules()`: `02-S3-LAYOUT.md` の3つのルールを投入
   
2. `S3/BucketSetup.swift`:
   - 上記の3つ（バージョニング、ライフサイクル、疎通）をまとめた高水準 API
   - 初回セットアップウィザードから呼ぶ
   - 全部成功するか、失敗時はロールバック不可能（バージョニングは無効化しない）

### ステップ6: Core 層（ハッシュとデバウンス）

1. `Core/HashCalculator.swift`:
   - `CryptoKit` の `SHA256` を使用
   - 64KB チャンクストリーミング
   - `actor` にせず `static` 関数で OK（ステートレス）
   ```swift
   static func sha256(of url: URL) async throws -> String {
       let handle = try FileHandle(forReadingFrom: url)
       defer { try? handle.close() }
       
       var hasher = SHA256()
       while autoreleasepool(invoking: {
           let chunk = handle.readData(ofLength: 65536)
           guard !chunk.isEmpty else { return false }
           hasher.update(data: chunk)
           return true
       }) {}
       
       return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
   }
   ```

2. `Core/DebounceQueue.swift`:
   - パスごとに最後のイベントから2秒待ってから flush
   - `actor` で実装
   - `AsyncStream` で出力

### ステップ7: マニフェスト

1. `S3/ManifestSharding.swift`:
   ```swift
   import CryptoKit
   
   enum ManifestSharding {
       static func shardId(for path: String) -> String {
           let hash = Insecure.SHA1.hash(data: Data(path.utf8))
           let firstByte = hash.first!
           return String(format: "%02x", firstByte)
       }
   }
   ```

2. `S3/Manifest.swift`:
   - `ManifestIndex` と `ManifestShard` の Codable 定義
   - JSON エンコード/デコードヘルパ
   - `02-S3-LAYOUT.md` のスキーマに完全準拠

3. `S3/S3Client.swift` に追加:
   - `getIndex() async throws -> (ManifestIndex, etag: String)?`
   - `putIndex(_ index: ManifestIndex, expectedETag: String?) async throws -> String`（新ETag返却）
   - `getShard(_ id: String) async throws -> (ManifestShard, etag: String)?`
   - `putShard(_ shard: ManifestShard, expectedETag: String?) async throws -> String`
   - `deleteShard(_ id: String) async throws`

楽観的ロックは `IfMatch` パラメータで実現。新規作成時は `IfNoneMatch: "*"`。

### ステップ8: ファイル監視

1. `Core/FileWatcher.swift`:
   - `FSEventStreamCreate` でストリーム作成
   - フラグ: `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes`
   - レイテンシ: 1.0 秒
   - コールバックから `AsyncStream<FileChangeEvent>` の Continuation に流す
   - イベントフラグから create/modify/delete/rename を判別

実装の難所:
- C コールバック関数から Swift 側にデータを渡す部分は `Unmanaged<...>.passUnretained` で `UnsafeMutableRawPointer` 経由
- ハードコード除外（`HardcodedIgnoreRules`）を最初のフィルタとして適用

### ステップ9: SyncEngine

1. `Core/SyncEngine.swift`:
   - `@Observable` クラス
   - 起動時に:
     - FileWatcher 開始
     - フルスキャン実行
     - upload_queue から未完了ジョブ復旧
   - ループで:
     - FileWatcher イベントを処理
     - upload_queue から処理可能なジョブを取り出し並列実行（最大5並列）
     - リトライ待ちジョブを `next_retry_at` で時刻管理

2. `S3/Uploader.swift`:
   - 単一ファイルのアップロード処理
   - `04-SYNC-LOGIC.md` の `processUpload` 参照
   - 100MB 超はスキップ（M1）

### ステップ10: UI

1. `App/TideApp.swift`（下記は M1 当時のスケッチ。現状は `NSApplicationDelegateAdaptor` 経由の eager bootstrap、`MenuBarLabel` による自前フレームアニメ、Scene は `settings`/`setup`/`versions`/`activity`/`about` の 5 つに拡張済み。現コードを正とする）:
   ```swift
   @main
   struct TideApp: App {
       @State private var environment = AppEnvironment()
       
       var body: some Scene {
           MenuBarExtra("Tide", systemImage: "icloud.and.arrow.up") {
               MenuBarContent(environment: environment)
           }
           .menuBarExtraStyle(.window)
           
           Window("Settings", id: "settings") {
               SettingsWindow(environment: environment)
           }
       }
   }
   ```

2. `UI/MenuBarContent.swift`:
   - 同期状態の表示（アイコン + テキスト）
   - 最終同期時刻
   - キュー件数
   - "Settings..." ボタン
   - "Pause" / "Resume" ボタン
   - "Quit" ボタン

3. `UI/SetupWizardWindow.swift`:
   - ステップ1: AWS 認証情報入力
   - ステップ2: バケット名・リージョン入力 → 接続テスト
   - ステップ3: バージョニング状態確認 → 未有効なら有効化確認
   - ステップ4: ライフサイクルルール投入
   - ステップ5: 同期フォルダ選択（NSOpenPanel）
   - ステップ6: 完了 → SyncEngine 起動

4. `UI/SettingsWindow.swift`:
   - 接続情報の確認・変更
   - 同期フォルダパス表示
   - 除外ルール（M1 では読み取り専用でハードコード除外を表示）
   - 詳細ログの表示（最近の sync_log）

### ステップ11: ロジックの検証用テスト

最低限以下のユニットテストを書く:

1. `ManifestShardingTests`: 同じパスは常に同じシャード ID になる、分布が偏らない
2. `HashCalculatorTests`: 既知のファイルのハッシュが既知の値と一致
3. `HardcodedIgnoreRulesTests`: 各種除外パターンが正しく動く
4. `DebounceQueueTests`: 連続イベントが集約される、独立したパスは独立して処理される

### ステップ12: 動作確認

1. テスト用 S3 バケットを作成
2. アプリ起動 → セットアップウィザード完了
3. 同期フォルダにファイルを追加 → S3 にアップロードされることを確認
4. ファイルを編集 → S3 が更新されることを確認
5. ファイルを削除 → S3 で delete marker が付くことを確認
6. アプリ再起動 → 未完了キューが復旧することを確認
7. AWS コンソールでマニフェスト（`.tide/index.json` と `.tide/shards/*`）が正しいことを確認

## 注意事項

### Swift Concurrency

- アプリ全体で Swift Concurrency（async/await, actor）を使う
- メインスレッド処理は `@MainActor` を明示
- `@Observable` は SwiftUI からの観察用、ロジック処理は別 actor

### エラー型

`Core/SyncError.swift` を作って、アプリ独自のエラー型を定義する:

```swift
enum SyncError: Error {
    case bucketNotAccessible(reason: String)
    case versioningNotEnabled
    case manifestUpdateFailed
    case fileTooLarge(size: Int64)
    case unsupportedFileType(path: String)
    case awsError(underlying: Error)
    case databaseError(underlying: Error)
    case ioError(underlying: Error)
}

extension SyncError {
    var isPreconditionFailed: Bool {
        // S3 の 412 Precondition Failed を判定
        // AWS SDK の具体的エラー型に応じて実装
    }
}
```

### ログ

`os.Logger` を使う:

```swift
import os

enum AppLogger {
    static let sync = Logger(subsystem: "org.izukawa.Tide", category: "sync")
    static let s3 = Logger(subsystem: "org.izukawa.Tide", category: "s3")
    static let db = Logger(subsystem: "org.izukawa.Tide", category: "database")
    static let ui = Logger(subsystem: "org.izukawa.Tide", category: "ui")
}

// 使用例
AppLogger.sync.info("Starting full scan of \(syncRoot)")
AppLogger.s3.error("Upload failed: \(error)")
```

### 並列度の制御

`AsyncSemaphore` 相当の機構が必要。Swift 標準にはないので、actor で自作するか、もしくはタスクグループで明示的に並列度を絞る:

```swift
await withTaskGroup(of: Void.self) { group in
    var inflight = 0
    let maxConcurrent = 5
    
    for item in items {
        if inflight >= maxConcurrent {
            await group.next()
            inflight -= 1
        }
        group.addTask { /* upload */ }
        inflight += 1
    }
}
```

### TODO マーカー

未実装部分には `// TODO(M2):` や `// TODO(M3):` のようなコメントを残す。後で grep で拾えるように。

例:
```swift
// TODO(M2): ここで S3 → ローカルのダウンロード処理を実装
// TODO(M3): 大ファイルはマルチパートアップロードに切り替え
```

## チェックリスト

M1 完了の判定基準:

- [ ] Xcode で `cmd+B` してエラー・ワーニングなしでビルドできる
- [ ] アプリ起動するとメニューバーにアイコンが出る
- [ ] 初回起動時にセットアップウィザードが出る
- [ ] AWS 認証情報を入力するとバケット接続テストが通る
- [ ] バケットのバージョニングが有効化される
- [ ] ライフサイクルルールが投入される
- [ ] 同期フォルダにファイルを追加すると S3 にアップロードされる
- [ ] ファイル変更を検知してアップロードされる
- [ ] ファイル削除で S3 に delete marker が付く
- [ ] マニフェスト（index.json と shards/*.json）が正しく書かれる
- [ ] アプリ再起動でも未完了キューが復旧する
- [ ] ハードコード除外（.DS_Store 等）がアップロードされない
- [ ] 100MB 超のファイルがスキップされ、エラーログが残る
- [ ] ユニットテストが全て通る

## M2 への引き継ぎポイント

M1 完了後、M2 着手前に確認すべきこと:

- マニフェストのスキーマに変更が必要か
- ローカル DB スキーマに変更が必要か
- エラーハンドリングで足りない部分はないか
- パフォーマンスの問題はないか（フルスキャンが遅い等）
