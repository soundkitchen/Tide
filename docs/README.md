# Tide - macOS ⇄ S3 同期ツール

本書はドキュメントセットの概観と索引（旧 `00-OVERVIEW.md` を v0.3.0 docs 監査で統合。
プロジェクト全体像・マイルストーンの単一の正はここ）。

## このドキュメントセットの構成

- `README.md`（本書）: プロジェクト全体像、マイルストーン、索引
- `01-ARCHITECTURE.md`: アーキテクチャ（モジュール構成・レイヤー・起動フロー）
- `02-S3-LAYOUT.md`: S3 バケットのデータレイアウト、マニフェスト仕様
- `03-LOCAL-DATABASE.md`: ローカル SQLite スキーマ（folderSync 世代の凍結台帳。fpOnly では DB を開かない）
- `04-SYNC-LOGIC.md`: 同期ロジック（現行 = fpOnly。3-way merge・マニフェスト RMW・FP 取り込み経路）
- `04a-SYNC-LOGIC-FOLDERSYNC.md`: folderSync 世代の同期ロジック記録（**削除予約** — FSEvents コードの物理撤去と同時にファイルごと削除）
- `06-SETUP-AND-BUILD.md`: 開発環境セットアップ、ビルド方法
- `07-M3-IMPLEMENTATION-GUIDE.md`: M3 実装記録（マルチパート・`.syncignore`・3-way merge・中断再開・帯域制御の確定記録と実測値）
- `08-IMPLEMENTATION-NOTES.md`: 会話で確定した実装決定の集積（旧 §7）
- `09-DEFERRED.md`: 据え置き項目・バックログ・解消済み記録（旧 §8）

> 欠番: `00`（本書へ統合）・`05`（M1 実装手順の過去ログ。現行と乖離した手順のため v0.3.0 docs 監査で削除 — 必要なら git 履歴を参照）。

## プロジェクト目的

macOS のクリーンインストール後の復旧を主目的とした、Dropbox 風のファイル同期ツール。バックエンドはユーザー自身の AWS S3 バケットを使用する。

## 設計原則

1. **シングルユーザー前提**: 同一の AWS アカウント・S3 バケットを、同一ユーザーが複数の Mac で使う想定
2. **データ損失より重複を選ぶ**: 競合時は両方保持してリネーム。「片方を消す」判断は絶対にしない
3. **S3 バージョニング前提**: 削除・上書きは全て S3 バージョニングで復元可能にする
4. **クリーンインストール復旧**: ローカル状態がゼロでも、S3 とユーザー認証情報だけで完全復旧できる
5. **macOS ネイティブ**: Swift + SwiftUI、macOS 26+ のみサポート

## 確定スコープ

### 対象機能（最終形）

- macOS 専用、Swift + SwiftUI、メニューバー常駐アプリ
- 単一の Tide フォルダ（FP ドメイン）⇄ 単一 S3 バケットの双方向同期（1 対 1）
- ファイルオンデマンド（File Provider モード = **唯一の稼働モード**。dataless プレースホルダをオンラインのみ実体化する `~/Library/CloudStorage/Tide` ドメイン。**v0.3.0 でユーザー目線から旧 FSEvents（folderSync）モードを削除** — boot 固定 #96 / ウィザード fpOnly ネイティブ化 #97 / 旧同期フォルダ削除 #98。コード本体はデッドコード温存 = 物理撤去は 2 台 soak 後。経緯は `09-DEFERRED.md` M5 節・v0.3.0 節）
- 暗号化なし（クライアント側暗号化なし、S3 側は SSE-S3 を全 PUT 経路で明示指定）
- ローカル変更は File Provider 拡張の書込コールバックが S3 へ直接反映（旧 FSEvents + デバウンス方式は v0.3.0 で到達不能化・コード温存）
- リモート変更は `RemoteChangeSignaler`（index HEAD の ETag 比較・既定 3 分間隔）で検知し FP ドメインへ signal
- 3-way merge による双方向同期
- 競合時は両方保持してリネーム
- S3 バージョニング有効化必須、ライフサイクルルール自動投入
- 削除は delete marker 経由、復元 UI あり
- `.git/` はデフォルト同期対象に含める
- `.syncignore`（gitignore 文法）対応
- 配布は自分用専用（コード署名・Notarization 不要）

### 対象外（やらない）

- ~~ファイルオンデマンド（File Provider Extension）~~（**M5 で対象に昇格・2026-07-02 決定**。`NSFileProviderReplicatedExtension` による dataless オンラインのみ実体化。下記マイルストーン M5 参照）
- クライアント側暗号化
- 複数ユーザー間のコラボレーション機能
- 共有リンク生成
- Web UI
- iOS / iPadOS 版
- 自動アップデート（Sparkle 等）

## マイルストーン

### M1: 一方向アップロード（実装完了）

**ゴール**: Mac A から S3 に変更が反映され続ける。マニフェストが正しく書かれる。

- メニューバーアプリの骨格
- 設定 UI（バケット名、リージョン、認証情報、同期フォルダ）
- 初回セットアップウィザード
- ローカル → S3 への単方向アップロード（削除含む）
- マニフェスト書き込み（シャーディング、楽観的ロック）
- SQLite でローカル状態管理
- 100MB 以下のファイルのみ対応（マルチパートは M3 で実装）
- 基本的なエラーハンドリングとリトライ

**この時点では「バックアップソフト」として動作する**。M2 で復元機能、M3 で本格的な双方向同期を実装する。

### M2: ダウンロードと復元（実装完了）

- S3 → ローカルへのダウンロード
- 「既存バケットから復元」フロー
- マニフェスト読み込み・差分計算
- 起動時・復帰時のフルチェック
- ポーリング（デフォルト3分）
- 削除の同期（リモートで削除されたものをローカルからも削除）

**M2 完了時点でクリーンインストール復旧が機能する。これが本プロジェクトの MVP ゴール。**

### M3: 双方向同期と競合解決、大ファイル対応（サブ A〜E 実装済み・M3 完了）

詳細な設計メモと実装状況は `07-M3-IMPLEMENTATION-GUIDE.md`、確定した実装判断は `docs/08-IMPLEMENTATION-NOTES.md` を参照。

- ✅ 3-way merge による双方向同期（サブ C・`ThreeWayMerge`）
- ✅ 競合検出と `<stem> (local copy YYYY-MM-DD HH-MM-SS).<ext>` リネーム（`ConflictNamer`）
- ✅ マルチパートアップロード / レンジダウンロード（サブ A・D。**自前ラッパ方式**で実装。`aws-sdk-swift-s3-transfer-manager` は不採用）
- ✅ 中断・再開機能（サブ D・`transfer_state` + Range 再開）
  - **現行（fpOnly）の読み替え**: FP の DL（`fetchContents`）に再開機構は無い（毎回先頭から・SHA 検証で担保）。`transfer_state` は凍結 DB 内 = folderSync 世代。
- ✅ `.syncignore` 対応（サブ B）
- ✅ 帯域制御（オプション・サブ E・トークンバケット `RateLimiter`。アップロード／ダウンロードの上限を Settings で MB/s 指定。既定は無制限）
  - **現行（fpOnly）の読み替え**: FP 拡張が配線するのは**アップロード側 limiter のみ**。`fetchContents` は limiter 非経由のため、Settings のダウンロード上限は fpOnly では実質 no-op。

### M4: 運用機能と磨き込み（実装済み）

- ✅ 削除済みファイルの復元 UI（「Version History」ウィンドウの「Deleted files」タブ。明示ボタンでフル列挙・逐次表示・キャンセル可）
- ✅ 過去バージョン参照 UI（同ウィンドウの「Versions」タブ。特定ファイルの版を時系列表示し、選んだ版を復元）
  - 列挙は `ListObjectVersions`、取得は `versionId` 指定、復元は「書き戻し → 再アップロード」方式（`RestoreService`）。遡及窓は概ね 90 日。詳細は `docs/02-S3-LAYOUT.md`「バージョン復元 / 削除済み復元」と `docs/08-IMPLEMENTATION-NOTES.md`。
  - **現行（fpOnly）の読み替え**: 復元は `S3RestoreService` による **S3 内復元**（tmp DL → 現行版 PUT・ローカル書き戻しなし）。「書き戻し → 再アップロード」（`RestoreService`）は folderSync 世代。
- ✅ 同期状況の詳細表示、エラー履歴
  - 「Sync Activity」ウィンドウ（sync_log の閲覧。種別フィルタ + ページング + 詳細コピー）。エラーは構造化型 `SyncIssue` に分類して表示し、生エラー文字列はオンデマンド参照のみ（`security/high.md` H2 / F4 解消）。メニューバーポップオーバーも刷新（ステータスヘッダー / 同期情報カード / 直近の同期 / 分類エラーサマリ / アイコンアクション）。詳細は `docs/08-IMPLEMENTATION-NOTES.md`。
  - **現行（fpOnly）の読み替え**: Sync Activity のソースは DB の sync_log ではなく **`FPEventLog`**（FP 拡張が書く App Group Caches の JSONL・Issue #83）。
- ✅ 通知（競合発生時・未バックアップ確定時）
  - macOS 通知（UserNotifications）。発火は「ユーザの介入が要る／取りこぼしが起きうる確定的な事象」だけに絞る: ① 競合コピー作成、② サイズ上限超過、③ リトライ give-up、④ 不安定ファイル（変化し続けて未バックアップ）、⑤ FP 拡張のユーザ OFF = 全同期停止（#103 で追加）。一過性のネットワークエラー等は出さない。許可は**初回発火時**にリクエスト。Settings の「Notifications」トグル（既定 on）で抑止可。通知クリックで Sync Activity を開く。判定は純粋関数 `NotificationPolicy`。詳細は `docs/08-IMPLEMENTATION-NOTES.md`。
- ✅ パフォーマンス最適化（pull コスト削減）
  - リモート pull の取り込み（`reconcileRemoteEntry`）に **stat ゲート**を追加。未変化シャードは entry が DB から再合成されるため、ローカルが DB と一致し DB がリモートをそのまま反映していれば hash も DB write もせずスキップする（証明可能な no-op）。内容一致時の DB 最新化は `download()` から専用 `markSynced` に分離し、残る hash も off-main 化（pull 中のメインスレッドブロックを解消）。判定は純粋関数 `ChangeDetector.reconcileIsNoop`。詳細は `docs/08-IMPLEMENTATION-NOTES.md`「reconcile 入口の stat ゲート」と `docs/04a-SYNC-LOGIC-FOLDERSYNC.md`。
  - **現行（fpOnly）の読み替え**: pull 経路ごと folderSync 世代（fpOnly に pull は無い）。

### M5: Files-On-Demand（File Provider・✅ 完了 — v0.3.0 で唯一の稼働モードへ）

当初「対象外」としていたファイルオンデマンドを対象に昇格した（v0.2.0 出荷後・2026-07-02 ユーザ決定）。
`NSFileProviderReplicatedExtension` により `~/Library/CloudStorage/Tide` ドメイン（レプリカ実体パスは
`Tide-Tide`）へ dataless プレースホルダを列挙し、開いた瞬間に S3 から実体化する。当初は**既存 FSEvents
モードと opt-in 並走**（未ソークの新モードが既存バックアップ経路を汚さない）で開発し、その後 FP-only
稼働へ切替（2026-07-25）→ v0.3.0 でユーザー目線から folderSync を削除した（下記）。3 ターゲット構成
（`TideCore` framework + `Tide` app + `TideFileProvider.appex`）。設計・進捗・フェーズ分割の詳細は
`09-DEFERRED.md` の M5 節、確定した実装判断は `08-IMPLEMENTATION-NOTES.md` を参照。

- ✅ Phase 1: `TideCore` framework 分離（app と拡張の共有コア・PR #48）
- ✅ Phase 2: App Group 移設 + App Sandbox 化 + security-scoped bookmark（PR #49）
- ✅ Phase 3: 読み取り materialize PoC（dataless → 開いた瞬間 S3 取得・PR #50）
- ✅ Phase 4: 増分列挙 + リモート追従（世代 SyncAnchor + `enumerateChanges`・PR #51）
- ✅ Phase 5: 双方向書込（「拡張 = 第 3 のデバイス」方式）— 5-0 signal チョークポイント（PR #56）/
  5-1 kind 変化対応（PR #57）/ 5-2 書込 PoC = deleteItem + modifyItem（PR #58）/
  5-3 createItem + dir 再帰削除（PR #59）/ 5-4 rename/reparent（PR #60）全マージ・
  実機受け入れ済み（2026-07-11）。書込系コールバックはこれで全対応
- ✅ 並走 UI の本実装化（2026-07-12）: 設定画面の FP セクションを正式化（experimental/PoC 表記を
  除去し双方向同期の実態説明へ）・`FileProviderPoC` → `FileProviderController` リネーム・
  ドメイン identifier `"poc"` → `"main"`（bootstrap の自動作り直し移行付き）
- ✅ FP 一本化・切替前の前提整備（Track A・2026-07-21）: #69（採用未了ウィンドウの削除黙殺・PR #71）と
  #67（pull 削除反映の空 dir 殻・PR #72）を修正、soak 負荷注入スクリプト（`tools/soak/churn.py`・PR #73）を整備
- ✅ FP-only 稼働モードへ切替（2026-07-25）: Track B（`ConfigStore.syncMode` + `RemoteChangeSignaler` +
  S3 内復元 + UI 縮退 + `soak-check --fp-only`）実装 → 切替ランブック実施 → launchd 常駐 soak 監視（#84）
- ✅ #40 の 1 週間ライブ soak 判定合格（2026-08-03・persistent DRIFT ゼロ）
- ✅ **v0.3.0: ユーザー目線からの folderSync 削除**（設計 2026-08-06 → 完了 2026-08-17）:
  #96 boot fpOnly 固定 + Sync mode UI 撤去（2026-08-08）/ #97 ウィザード fpOnly ネイティブ化（2026-08-11）/
  #98 旧同期フォルダ `~/Tide` 削除 + docs 反映（2026-08-17）。設計原本 = `docs/09`「v0.3.0」節
- ⏸ FSEvents コードの物理撤去（真の一本化）は FP-only 無事故実績 + 2 台 soak 後の将来段階（据え置き）。
  詳細は `docs/09` の #40 節・M5 節
- 実施フェーズの継続作業（v0.3.0 には含めない）: 重要ファイル投入 + Keep Downloaded 運用・#93 ほか

## 技術スタック

- **言語**: Swift 6
- **UI**: SwiftUI + AppKit（メニューバー部分）
- **最低 OS**: macOS 26.0 (Tahoe)
- **AWS SDK**: AWS SDK for Swift（公式）
  - マルチパート / レンジダウンロードは**自前ラッパ方式**で実装。`aws-sdk-swift-s3-transfer-manager` は不採用（上記 M3 サブ A・D を参照）
- **SQLite**: GRDB.swift（folderSync 世代の凍結資産。fpOnly では DB を開かない — `03-LOCAL-DATABASE.md`）
- **変更検知**: File Provider 書込コールバック + `RemoteChangeSignaler`（index HEAD ETag 比較。旧 CoreServices/FSEvents 監視は v0.3.0 で到達不能のデッドコード温存）
- **認証情報保管**: Keychain (Security framework)
- **ビルド**: Xcode + Swift Package Manager
- **配布**: 自分のマシンに `xcodebuild` でビルドして `~/Applications/` に配置

## 重要な前提

- AWS SDK for Swift で `AWSS3` モジュールを利用
- マニフェストは JSON（ローカル SQLite は folderSync 世代の凍結資産）
- 全ての時刻は UTC、ISO8601 形式で保存
- ファイルパスは Tide フォルダ（FP ドメイン）ルートからの相対パス、POSIX 区切り（`/`）
- ハッシュは SHA-256（hex 小文字）
- Device ID は初回起動時にランダム生成し group UserDefaults に保存
