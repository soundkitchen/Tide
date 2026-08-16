# Tide アーキテクチャ（v0.3.0 = fpOnly 時点の現状）

> M1 起草 → M2〜M4 で更新 → **M5（Files-On-Demand）と v0.3.0（folderSync のユーザー目線削除）で全面再構成**した。
> 本書は現行 = fpOnly（File Provider）稼働のアーキテクチャを説明する。
> 旧 FSEvents（folderSync）世代のコンポーネント（`SyncEngine` / `FileWatcher` 等）は**到達不能のデッドコード**として
> コード温存されており（復帰は git revert のみ・物理撤去は 2 台 soak 後ゲート）、その同期ロジック仕様は
> [`04a-SYNC-LOGIC-FOLDERSYNC.md`](04a-SYNC-LOGIC-FOLDERSYNC.md) に退避した。
> M3 で確定した設計判断は [`07-M3-IMPLEMENTATION-GUIDE.md`](07-M3-IMPLEMENTATION-GUIDE.md)、
> 会話で確定した実装判断は [`08-IMPLEMENTATION-NOTES.md`](08-IMPLEMENTATION-NOTES.md) を参照。

## 全体像（3 ターゲット × 2 プロセス）

v0.3.0 の Tide は **3 ターゲット**（`TideCore` framework + `Tide` app + `TideFileProvider.appex`）**2 プロセス**で動く:

```
┌──────────────────────────────┐      ┌───────────────────────────────────┐
│ Tide.app（メニューバー常駐）      │      │ TideFileProvider.appex             │
│                              │      │ （fileproviderd が起動する拡張）       │
│  UI（SwiftUI）                │      │                                   │
│  RemoteChangeSignaler         │      │  FileProviderExtension            │
│   （index HEAD ETag・既定 180s）│      │   ├ 列挙: ManifestSnapshotLoader   │
│  FileProviderController       │      │   │   → ManifestTree/TreeDiff     │
│   （ドメイン登録 / signal 配線）  │      │   ├ 実体化: fetchContents          │
│  S3RestoreService（S3 内復元） │      │   │   （streamObject + SHA 検証）    │
│  FPEventLog（読み）            │      │   └ 書込: ExtensionWriter          │
└──────────────┬───────────────┘      │       → ManifestUpdater（共有 RMW）  │
               │ signalEnumerator      │  FPEventLog（書き手 = 拡張のみ）      │
               └──────────────────────▶└─────────────────┬─────────────────┘
                                                         │
        両プロセスとも TideCore framework（共有コア）に依存      ▼
        ┌────────────────────────────────────────────────────────────┐
        │ S3 バケット: files/<path> 本体 + .tide/index.json + shards/  │
        └────────────────────────────────────────────────────────────┘
```

- **書込（ローカル → S3）**: Finder / アプリでの Tide フォルダ操作を fileproviderd が拡張の
  `createItem` / `modifyItem` / `deleteItem`（+ rename/reparent）コールバックへ届け、`ExtensionWriter` が
  S3 本体とマニフェストを直接書く（「拡張 = 第 3 のデバイス」方式）。マニフェスト更新は app 側アップロードと
  **同一チョークポイント `ManifestUpdater`**（3-way `decideUpload` + CAS リトライ）を通る。拡張は
  **DB / syncRoot / tmp に非接触**。
- **取り込み（S3 → ローカル）**: `Tide.app` の `RemoteChangeSignaler` が `.tide/index.json` の
  **HEAD ETag** を定期比較（既定 180 秒 + wake / ネットワーク復帰契機）し、変化時のみ FP ドメインへ
  `signalEnumerator`。増分本体は拡張の `enumerateChanges`（`ManifestTreeDiff`）が担い、実体は
  ユーザーがファイルを開いた瞬間に `fetchContents` が S3 から取得する（dataless オンデマンド実体化）。
- **同期面**: `~/Library/CloudStorage/Tide` ドメイン（レプリカ実体パスは `Tide-Tide`・Finder では
  「場所」の Tide）。旧同期フォルダ（`~/Tide`）は v0.3.0 #98 で削除済み。

### 実行基盤

- **App Sandbox 有効**（app / 拡張とも。M5 Phase 2〜）。
- **App Group** `G5G54TCH8W.org.izukawa.Tide`（チーム ID プレフィックス形式必須 — `group.` 形式は
  macOS では TCC 保護され UI の無い拡張が拒否される。定数は `TideAppGroup`）。
- 設定は **group UserDefaults**（`ConfigStore`）、認証情報は **Data Protection Keychain**
  （`kSecAttrAccessGroup` 明示・app / 拡張で共有）。
- **fpOnly はローカル DB（`db.sqlite`）を開かない**（GRDB スキーマは folderSync 復帰資産として
  コンパイル温存 = `03-LOCAL-DATABASE.md`）。fpOnly の永続状態は App Group Caches の
  ファイル群（`FPEventLog` / `PersistedPathSet` / `ManifestGenerationLog` 等・同 03 参照）。
- 新規セットアップは **security-scoped bookmark を発行しない**（folderSync 世代の解決系はデッド経路温存・
  `security/low.md` L1）。

## モジュール構成

```
Tide/（リポジトリルート）
├── Tide.xcodeproj                    xcodegen 生成（git 追跡対象、直接編集不可）
├── project.yml                       xcodegen の入力（3 ターゲット定義・Info.plist もここから生成）
├── Makefile                          build / test / reset / fresh の統合
│
├── TideCore/                         【framework: app と拡張の共有コア・APPLICATION_EXTENSION_API_ONLY】
│   ├── Core/                         純粋ロジック（MainActor 非依存）
│   │   ├── ThreeWayMerge.swift        3-way merge 判定（decide / decideUpload）(M3)
│   │   ├── PathValidator.swift        リモート由来パス / シャード ID の検証 (security)
│   │   ├── HashCalculator.swift       SHA-256 計算（ストリーミング）
│   │   ├── IgnoreRules.swift          ハードコード除外 + 既定の機密ファイル除外
│   │   ├── IgnoreDecision.swift       除外判定の統合 (M3)
│   │   ├── SyncIgnoreMatcher.swift    .syncignore パターンマッチ（線形時間 DP）(M3)
│   │   ├── ManifestTree.swift         マニフェスト → FP 列挙ツリー合成 (M5)
│   │   ├── ManifestTreeDiff.swift     世代間 diff（enumerateChanges 用）(M5)
│   │   ├── MaterializedBadge.swift    実体化連動バッジ判定（#65）
│   │   ├── FileProviderWritePolicy.swift  FP 書込のパス合成 / 検証 (M5 Phase 5)
│   │   ├── ConflictNamer.swift        コンフリクト時のリネーム命名 (M2)
│   │   ├── NoFollowFileReader.swift   O_NOFOLLOW 単一 FD 読み出し（TOCTOU 解消）(M3)
│   │   ├── RateLimiter.swift          帯域制御（トークンバケット）(M3)
│   │   ├── SyncError.swift / SyncIssueClassifier.swift / AppLogger.swift ほか
│   │   └── （folderSync 世代: ChangeDetector / StabilityCheck / RestoreService / DeletedFilesCache 等）
│   ├── S3/
│   │   ├── S3Client.swift             AWS SDK ラッパー（実型名 TideS3Client・SSE-S3 / PAB / lifecycle）
│   │   ├── Manifest.swift             マニフェスト型 + JSON 入出力
│   │   ├── ManifestSharding.swift     シャード振り分け（SHA-1 先頭バイト）
│   │   ├── Uploader.swift             ManifestUpdater（共有 RMW チョークポイント）+ folderSync Uploader
│   │   ├── ManifestStore.swift        マニフェスト読み書きシーム（app / 拡張共用）(M5)
│   │   ├── IndexUpdateCoalescer.swift index 更新のプロセス内コアレス（#91）
│   │   ├── ConditionalRetryPolicy.swift  CAS リトライ（shard 5 回 / index 8 回・#91）
│   │   ├── ManifestSnapshot.swift     DB 非依存の全シャード読みスナップショット (M5)
│   │   ├── ManifestGenerationCache/Log.swift  拡張の世代キャッシュ / 追記ログ (M5)
│   │   ├── ManifestIgnoreCache.swift  FP createItem 用 .syncignore 取得（versionId 固定 + sha 検証）
│   │   ├── MultipartUploader.swift / PartPlan.swift  マルチパート（自前ラッパ）(M3)
│   │   ├── S3RestoreService.swift     S3 内復元（fpOnly の Version History）(Track B-2)
│   │   ├── ObjectVersionHistory.swift バージョン一覧 / 削除済み列挙 (M4)
│   │   ├── PersistedPathSet.swift     拡張の永続パス集合（バッジ報告済み / 仮想フォルダ / 後始末予約）
│   │   ├── BucketPolicyBuilder.swift  HTTPS 強制バケットポリシー生成（C3）
│   │   ├── KnownRegions.swift         AWS リージョン一覧（Picker 用）
│   │   └── （folderSync 世代: ManifestReader / Downloader）
│   ├── Storage/
│   │   ├── ConfigStore.swift          group UserDefaults ラッパー
│   │   ├── KeychainStore.swift        認証情報保管（Data Protection Keychain）
│   │   ├── TideAppGroup.swift         App Group 定数 / コンテナパス解決
│   │   ├── FPEventLog.swift           FP イベントの共有 JSONL（Sync Activity のソース・#83）
│   │   ├── LegacyStateMigrator.swift  旧ロケーションからの一度きり移行
│   │   └── （folderSync 世代: LocalDatabase / Migrations / TransferStateStore）
│   └── Models/
│       ├── FileEntry.swift            マニフェストのファイルエントリ（型名は ManifestFileEntry）
│       ├── AWSCredentials.swift / SyncStatus.swift / SyncIssue.swift / TransferProgress.swift / SyncEvent.swift
│
├── Tide/                             【app: メニューバー常駐・UI と駆動層】
│   ├── App/
│   │   ├── TideApp.swift              @main、メニューバー常駐（NSApplicationDelegateAdaptor で eager bootstrap）
│   │   ├── AppEnvironment.swift       依存性注入コンテナ + bootstrap + factoryReset
│   │   └── NotificationManager.swift  UserNotifications 配信（@MainActor・初回発火時に許可要求）(M4)
│   ├── UI/
│   │   ├── MenuBarContent.swift / MenuBarPresentation.swift   ポップオーバー
│   │   ├── SettingsWindow.swift       設定画面（FP セクション / 帯域上限 / 通知トグル / Diagnostics）
│   │   ├── SetupWizardWindow.swift    初回セットアップ（fpOnly ネイティブ 5 ステップ・#97）
│   │   ├── VersionHistoryWindow/Model.swift  過去バージョン / 削除済み復元 (M4・fpOnly は S3 内復元)
│   │   ├── SyncActivityWindow/Model.swift    同期アクティビティ（fpOnly ソース = FPEventLog）
│   │   └── AboutWindow.swift / UIHelpers.swift
│   ├── Core/
│   │   ├── RemoteChangeSignaler.swift リモート変化検知（index HEAD ETag → FP signal）【現行の駆動】
│   │   ├── FileProviderController.swift  FP ドメイン登録 / 解除・signal 配線・status 観測
│   │   ├── NotificationPolicy.swift   通知発火判定（純粋関数・5 事象のみ）(M4 + #103)
│   │   ├── DiagnosticsExporter.swift / SettingsTransfer.swift
│   │   └── （folderSync 世代: SyncEngine(+FullScan) / FileWatcher / DebounceQueue / RemoteOpGate）
│   └── Resources/                     Assets.xcassets / Localizable.xcstrings（en source / ja 翻訳）
│
├── TideFileProvider/                 【appex: NSFileProviderReplicatedExtension・DB 非接触】
│   ├── FileProviderExtension.swift    コールバック本体（列挙 anchor / fetchContents / 書込系）
│   ├── FileProviderEnumerator.swift   working set / ディレクトリ列挙・enumerateChanges
│   ├── FileProviderItem.swift         item 表現（f:/d: identifier・capabilities・バッジ / evict）
│   ├── ExtensionWriter.swift          書込系の実務（S3 PUT / delete / move → ManifestUpdater 合流）
│   ├── ExtensionServices.swift        共有サービス束（S3 client / ignore / ログ・DB 非接触の不変条件）
│   ├── MaterializedSetObserver.swift  実体化セット観測（バッジ live 側）
│   └── Resources/Localizable.xcstrings  拡張の user-facing 文言（app 側とは別カタログ）
│
├── TideTests/                        ユニットテスト（65 ファイル・folderSync 回帰網含む）
└── tools/soak/                       soak 監視（consistency_check.py / launchd 常駐・#40 #84）
```

「会話を通じて決まったが本書で説明しきれていない実装上の判断」はプロジェクトルートの
`CLAUDE.md` §7 と `08-IMPLEMENTATION-NOTES.md` に集約している。

## レイヤー構成と依存方向

```
Tide.app                                TideFileProvider.appex
┌───────────────────────┐              ┌───────────────────────┐
│ UI Layer (SwiftUI)    │              │ FP コールバック層        │
│  MenuBar / Settings / │              │  FileProviderExtension │
│  Wizard / History     │              │  Enumerator / Item     │
└──────────┬────────────┘              └──────────┬────────────┘
           │ observes                             │ uses
           ▼                                      ▼
┌───────────────────────┐              ┌───────────────────────┐
│ 駆動層 (Tide/Core)     │              │ ExtensionWriter /      │
│  RemoteChangeSignaler │              │ ExtensionServices      │
│  FileProviderController│             └──────────┬────────────┘
└──────────┬────────────┘                         │
           ▼                                      ▼
┌─────────────────────────────────────────────────────────────┐
│ TideCore framework（共有コア）                                 │
│  Core（純粋ロジック）/ S3（Client・ManifestUpdater）/            │
│  Storage（ConfigStore・Keychain・FPEventLog）/ Models          │
└─────────────────────────────────────────────────────────────┘
```

依存は常に下向き（UI / コールバック層 → 駆動層 → TideCore）。逆方向の依存は禁止。
app と拡張の間に直接のプロセス間依存は無く、**S3（マニフェスト）と App Group（設定 / Keychain /
FPEventLog / signal）だけを接点にする**。

## 主要コンポーネント（現行 = fpOnly）

### RemoteChangeSignaler（app 側の駆動）

- `.tide/index.json` の **HEAD ETag** をポーリング間隔（`pollingIntervalSeconds`・既定 180 秒・下限 30
  クランプ）+ wake / ネットワーク復帰の即時契機で比較し、変化時のみ
  `FileProviderController.signalRemoteChanges()` を呼ぶ。
- **DB / shard_state に構造的に非接触**（HEAD 1 発 ≒ 数十バイト/周期）。index 不在は無反応・
  HEAD 失敗は保持 ETag を進めない・初回はベースライン確立 + 無条件 1 回 signal。
- 詳細は `08-IMPLEMENTATION-NOTES.md`「FP-only 稼働モード B-0」節。

### FileProviderController（app 側のドメイン管理）

- FP ドメインの登録 / 解除（Disable/Enable = ドメイン作り直し。**必ずチョークポイント
  `removeAllDomainsInvalidatingRegistries` 経由** = #104 の epoch リセット）・`signalEnumerator` 配線・
  `domainStatus()`（enabled / userDisabled / notRegistered）の観測（#103 の拡張 OFF 検出）。

### FileProviderExtension（拡張のコールバック本体）

- **列挙**: `ManifestSnapshotLoader`（全シャード読み・DB 非依存）→ `ManifestTree` 合成 →
  世代 SyncAnchor + `enumerateChanges`（`ManifestTreeDiff`）で増分配信。item identifier は
  kind 織り込み（`f:<path>` / `d:<path>`・Phase 5-1）。
- **実体化**: `fetchContents` = versionId 固定の `streamObject` + サイズ / SHA-256 検証。
- **書込**: `createItem` / `modifyItem` / `deleteItem` / rename・reparent を `ExtensionWriter` が処理し、
  S3 本体 + `ManifestUpdater`（3-way `decideUpload`・CAS）へ合流。除外（機密網 / symlink /
  `.syncignore`）は `ExcludedFromSync` で拒否 = ローカル温存。
- **バッジ / evict**: 実体化連動バッジ（#65・reported = `PersistedPathSet`）と `.allowsEvicting`（#105）。
- 詳細は `04-SYNC-LOGIC.md` と `08-IMPLEMENTATION-NOTES.md` M5 各節。

### ManifestUpdater（共有チョークポイント・TideCore/S3/Uploader.swift 内）

- マニフェストの read-modify-write を一手に引き受ける: 権威シャード読み → `ThreeWayMerge.decideUpload`
  判定 → CAS 書込（`ConditionalRetryPolicy`）→ index 更新（`IndexUpdateCoalescer` でプロセス内コアレス）。
- 競合は `SyncError.uploadConflict` で安全中断（リトライに飲ませない）。部分完了は
  `indexUpdateFailedAfterCommit` / `.removedIndexStale` で区別（#91）。
- 詳細は `02-S3-LAYOUT.md`「マニフェスト更新」と `04-SYNC-LOGIC.md`。

### S3Client

責務: AWS SDK for Swift のラッパー、リトライ / エラーハンドリングの統一、認証情報の解決。
ファイル名は `S3Client.swift` だが実型名は `TideS3Client`。

```swift
final class TideS3Client: @unchecked Sendable {
    init(credentials: AWSCredentials, region: String, bucket: String, deviceId: String) throws

    // Bucket
    func checkBucketAccess() async throws
    func headBucket(...) / createBucket(...)                          // ウィザードのバケット作成分岐
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
    func copyObject(...)                                             // rename/reparent（versionId 固定）(M5 Phase 5-4)
    func listObjectVersions(...) async throws -> ObjectVersionPage    // M4 バージョン履歴

    // Manifest（楽観的ロックは ifMatch / ifNoneMatch。戻り値は新 ETag）
    func getIndex() async throws -> ManifestFetch<ManifestIndex>?
    func putIndex(_ index: ManifestIndex, ifMatch: String?) async throws -> String
    func getShard(_ id: String) async throws -> ManifestFetch<ManifestShard>?
    func putShard(_ shard: ManifestShard, ifMatch: String?) async throws -> String
    func deleteShard(_ id: String) async throws
}
```

> マルチパート（`createMultipartUpload` / `uploadPart` / `completeMultipartUpload` /
> `abortMultipartUpload`）とストリーミング DL（`streamObject`）は M3 で追加。詳細は
> [`07-M3-IMPLEMENTATION-GUIDE.md`](07-M3-IMPLEMENTATION-GUIDE.md) を参照。

### Manifest

マニフェストデータの読み書き・シャード分割・楽観的ロック（`If-Match`）。詳細は `02-S3-LAYOUT.md`。

### S3RestoreService（fpOnly の復元）

Version History / 削除済み復元の実行系。tmp DL → 現行版 PUT → `ManifestUpdater` 合流の
**S3 内復元**（ローカル書き戻しなし）。詳細は `08-IMPLEMENTATION-NOTES.md`「FP-only 稼働モード B-2」節。

### FPEventLog（fpOnly の Sync Activity ソース）

FP 拡張が書く App Group Caches の追記型 JSONL（書き手 = 拡張のみ・サイズ上限ローテーション）。
Sync Activity ウィンドウは fpOnly でこれを読む（#83）。

### HashCalculator

ファイルの SHA-256 をストリーミング計算（64KB チャンク・メモリに全部載せない）。

```swift
struct HashCalculator {
    static func sha256(of url: URL, chunkSize: Int = 65_536) throws -> String
}
```

### folderSync 世代のコンポーネント（デッドコード温存）

`SyncEngine`（FSEvents 同期の中枢）/ `FileWatcher`（FSEvents ラッパー）/ `DebounceQueue` /
`ChangeDetector` / `StabilityCheck` / `LocalDatabase`（GRDB）/
`ManifestReader` / `Downloader` / `RestoreService` / `TransferStateStore`。
いずれも v0.3.0 で到達経路ゼロ（起動もインスタンス化もされない）。
**例外 = `RemoteOpGate`**: 本来の用途（pull/restore 直列化）はデッドだが、**インスタンスは
`setupGate` として毎起動生成され、bootstrap / completeSetup / factoryReset の非再入ロックに
流用中**（上記起動フロー参照。物理撤去時は setupGate の代替実装が必要 = 撤去対象リストに
そのまま含めてはならない）。仕様は
[`04a-SYNC-LOGIC-FOLDERSYNC.md`](04a-SYNC-LOGIC-FOLDERSYNC.md) と `03-LOCAL-DATABASE.md`、
回帰テスト網は `TideTests/` に維持（復帰は git revert + `09-DEFERRED.md`「revert 復帰ランブック」）。

## 起動フロー（現行 = fpOnly）

```
[アプリ起動（AppDelegate.applicationDidFinishLaunching → eager bootstrap）]
    │
    ├─ XCTest 実行中（isRunningXCTests）→ no-op で抜ける
    │
    ▼
[LegacyStateMigrator（旧ロケーションからの一度きり移行・既移行なら no-op）]
    │
    ▼
[ConfigStore で設定読み込み + syncMode の正規化書込（無条件 fpOnly・#96）]
    │
    ├─ 設定がない（初回）
    │       │
    │       ▼
    │  [SetupWizard 表示（fpOnly ネイティブ 5 ステップ・#97）]
    │       ├─ credentials: AWS 認証情報入力
    │       ├─ bucket: リージョン / バケット名（接続テスト・無ければ作成分岐）
    │       ├─ provisioning: バージョニング / PAB / ライフサイクル / TLS ポリシー・.syncignore seed（新規バケット時）
    │       ├─ fileProvider: FP ドメイン登録 + システム設定での拡張有効化ゲート（OFF なら進めない）
    │       └─ done →（completeSetup が config/Keychain 保存 → enable → signaler 起動を一括保証）
    │
    ├─ 設定あり
    │       │
    │       ▼
    │  [launchEngineFromCurrentConfig = 無条件 fpOnly]
    │       ├─ Keychain から資格情報 → TideS3Client 構築
    │       ├─ FP ドメイン status 観測（#103 の OFF 検出）+ stale 通知掃除
    │       ├─ RemoteChangeSignaler.start()（ベースライン確立 + 初回 signal）
    │       └─ TLS ポリシー自己修復を detached で冪等適用
    │       ※ DB / syncRoot / bookmark には一切触れない（SyncEngine は構築されない）
    │
    ▼
[メニューバーアイコン表示]
```

**bootstrap の起動契機（eager）**: bootstrap は `@NSApplicationDelegateAdaptor` の
`applicationDidFinishLaunching` から eager に実行する（`AppEnvironment` も `AppDelegate` が保持）。
`MenuBarExtra(.window)` のポップオーバーコンテンツは初回オープン時に初めて生成されるため、bootstrap を
`MenuBarContent.task` だけに置くと「メニューを開くまで何も始まらない」事故になる。`MenuBarContent.task`
にも冪等な bootstrap 呼びを残し（未設定時のウィザード表示の保険）、`AppEnvironment.bootstrap()` は
`engine != nil || signaler != nil` と `setupGate`（`RemoteOpGate` 流用の非再入ロック）で再入ガード済み。
**XCTest 実行中（`ProcessInfo.isRunningXCTests` = `XCTestConfigurationFilePath` の有無）は `bootstrap()`
冒頭で no-op で抜ける** — `make test` は本体アプリをテストホストとして起動するため、抑止しないと
テストのたびに実 S3 と通信してしまう（実ユーザ向けの起動挙動は不変）。

## エラーハンドリング方針

- **ネットワークエラー**: fileproviderd のコールバック単位で拡張がエラーを返し、fileproviderd 側の
  再試行に委ねる（app 側の HEAD 失敗は保持 ETag を進めず次契機で回収）。
- **認証エラー**: 即座にユーザーに通知。リトライしない。設定画面を開いてもらう。
- **マニフェスト更新の楽観的ロック失敗（412/409）**: `ConditionalRetryPolicy` で shard 5 回 / index 8 回
  リトライ（指数バックオフ + ジッタ・その都度再読み込み）。`SyncError` は素通し（`uploadConflict` を
  リトライに飲ませない）。
- **エラーの UI 表示**: 構造化型 `SyncIssue` に分類（`SyncIssueClassifier`）。生エラー文字列は
  rawDetail 隔離。

## ログ出力

- `os.Logger` を使用
- サブシステム: `org.izukawa.Tide`
- カテゴリ: `sync`, `s3`, `database`, `ui`, `watcher`, `fileprovider`（File Provider 拡張・M5 Phase 3〜）
- レベル: debug / info / error
- リリースビルドでも error は残す
- エラー / パス / リモートデータ由来の文字列は必ず `privacy: .private`（`CLAUDE.md` §3）
