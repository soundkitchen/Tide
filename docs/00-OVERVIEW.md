# Tide - macOS ⇄ S3 同期ツール

## このドキュメントセットの構成

- `00-OVERVIEW.md`（本書）: プロジェクト全体像、マイルストーン
- `01-ARCHITECTURE.md`: M1 のアーキテクチャ詳細
- `02-S3-LAYOUT.md`: S3 バケットのデータレイアウト、マニフェスト仕様
- `03-LOCAL-DATABASE.md`: ローカル SQLite スキーマ
- `04-SYNC-LOGIC.md`: 同期アルゴリズム（M1 では片方向のみ）
- `05-IMPLEMENTATION-GUIDE.md`: Claude Code 向けの実装手順（M1 当時の過去ログ）
- `06-SETUP-AND-BUILD.md`: 開発環境セットアップ、ビルド方法
- `07-M3-IMPLEMENTATION-GUIDE.md`: M3（双方向同期・マルチパート・`.syncignore`・中断再開・帯域制御）の実装ガイド
- `08-IMPLEMENTATION-NOTES.md`: 会話で確定した実装決定の集積（旧 §7）
- `09-DEFERRED.md`: 据え置き項目・バックログ・解消済み記録（旧 §8）
- `README.md`: ドキュメントセットの索引

## プロジェクト目的

macOS のクリーンインストール後の復旧を主目的とした、Dropbox 風のファイル同期ツール。バックエンドはユーザー自身の AWS S3 バケットを使用する。

## 設計原則

1. **シングルユーザー前提**: 同一の AWS アカウント・S3 バケットを、同一ユーザーが複数の Mac で使う想定
2. **データ損失より重複を選ぶ**: 競合時は両方保持してリネーム。「片方を消す」判断は絶対にしない
3. **S3 バージョニング前提**: 削除・上書きは全て S3 バージョニングで復元可能にする
4. **クリーンインストール復旧**: ローカル DB がゼロでも、S3 とユーザー認証情報だけで完全復旧できる
5. **macOS ネイティブ**: Swift + SwiftUI、macOS 26+ のみサポート

## 確定スコープ

### 対象機能（最終形）

- macOS 専用、Swift + SwiftUI、メニューバー常駐アプリ
- 単一同期フォルダ → 単一 S3 バケットの双方向同期
- 全ファイルをローカル保持（FSEvents モード。**M5 でファイルオンデマンド = File Provider モードを追加中** — dataless プレースホルダをオンラインのみ実体化する `~/Library/CloudStorage/Tide` ドメイン。既存 FSEvents モードと opt-in 並走。進捗は `09-DEFERRED.md` M5 節）
- 暗号化なし（クライアント側暗号化なし、S3 側暗号化は AWS デフォルトに従う）
- ローカル変更は FSEvents + デバウンスで即時アップロード
- リモート変更は起動時・スリープ復帰時・ネットワーク復帰時・定期ポーリング（デフォルト3分）で検知
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
- ✅ `.syncignore` 対応（サブ B）
- ✅ 帯域制御（オプション・サブ E・トークンバケット `RateLimiter`。アップロード／ダウンロードの上限を Settings で MB/s 指定。既定は無制限）

### M4: 運用機能と磨き込み（実装済み）

- ✅ 削除済みファイルの復元 UI（「Version History」ウィンドウの「Deleted files」タブ。明示ボタンでフル列挙・逐次表示・キャンセル可）
- ✅ 過去バージョン参照 UI（同ウィンドウの「Versions」タブ。特定ファイルの版を時系列表示し、選んだ版を復元）
  - 列挙は `ListObjectVersions`、取得は `versionId` 指定、復元は「書き戻し → 再アップロード」方式（`RestoreService`）。遡及窓は概ね 90 日。詳細は `docs/02-S3-LAYOUT.md`「バージョン復元 / 削除済み復元」と `docs/08-IMPLEMENTATION-NOTES.md`。
- ✅ 同期状況の詳細表示、エラー履歴
  - 「Sync Activity」ウィンドウ（sync_log の閲覧。種別フィルタ + ページング + 詳細コピー）。エラーは構造化型 `SyncIssue` に分類して表示し、生エラー文字列はオンデマンド参照のみ（`security/high.md` H2 / F4 解消）。メニューバーポップオーバーも刷新（ステータスヘッダー / 同期情報カード / 直近の同期 / 分類エラーサマリ / アイコンアクション）。詳細は `docs/08-IMPLEMENTATION-NOTES.md`。
- ✅ 通知（競合発生時・未バックアップ確定時）
  - macOS 通知（UserNotifications）。発火は「ユーザの介入が要る／取りこぼしが起きうる確定的な事象」だけに絞る: ① 競合コピー作成、② サイズ上限超過、③ リトライ give-up、④ 不安定ファイル（変化し続けて未バックアップ）。一過性のネットワークエラー等は出さない。許可は**初回発火時**にリクエスト。Settings の「Notifications」トグル（既定 on）で抑止可。通知クリックで Sync Activity を開く。判定は純粋関数 `NotificationPolicy`。詳細は `docs/08-IMPLEMENTATION-NOTES.md`。
- ✅ パフォーマンス最適化（pull コスト削減）
  - リモート pull の取り込み（`reconcileRemoteEntry`）に **stat ゲート**を追加。未変化シャードは entry が DB から再合成されるため、ローカルが DB と一致し DB がリモートをそのまま反映していれば hash も DB write もせずスキップする（証明可能な no-op）。内容一致時の DB 最新化は `download()` から専用 `markSynced` に分離し、残る hash も off-main 化（pull 中のメインスレッドブロックを解消）。判定は純粋関数 `ChangeDetector.reconcileIsNoop`。詳細は `docs/08-IMPLEMENTATION-NOTES.md`「reconcile 入口の stat ゲート」と `docs/04-SYNC-LOGIC.md`。

### M5: Files-On-Demand（File Provider・着手中 2026-07-02〜）

当初「対象外」としていたファイルオンデマンドを対象に昇格した（v0.2.0 出荷後・2026-07-02 ユーザ決定）。
`NSFileProviderReplicatedExtension` により `~/Library/CloudStorage/Tide` ドメインへ dataless
プレースホルダを列挙し、開いた瞬間に S3 から実体化する。**既存 FSEvents モードは残して opt-in 並走**
（未ソークの新モードが既存バックアップ経路を汚さない）。3 ターゲット構成（`TideCore` framework +
`Tide` app + `TideFileProvider.appex`）。設計・進捗・フェーズ分割の詳細は `09-DEFERRED.md` の M5 節、
確定した実装判断は `08-IMPLEMENTATION-NOTES.md` を参照。

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
- ⏸ 以降: **1 台加速 soak**（2 台 soak が当面不可のため #40 の代替ゲートとする・ユーザ確定 2026-07-18）→
  **FP-only 稼働モード実装**（FSEvents コードは温存・モード可逆）→ 切替。
  コード撤去（真の一本化）は FP-only 無事故実績 + 2 台 soak 後の将来段階。詳細は `docs/09` の #40 節・M5 節

## 技術スタック

- **言語**: Swift 6
- **UI**: SwiftUI + AppKit（メニューバー部分）
- **最低 OS**: macOS 26.0 (Tahoe)
- **AWS SDK**: AWS SDK for Swift（公式）
  - マルチパート / レンジダウンロードは**自前ラッパ方式**で実装。`aws-sdk-swift-s3-transfer-manager` は不採用（上記 M3 サブ A・D を参照）
- **SQLite**: GRDB.swift
- **ファイル監視**: CoreServices (FSEvents)
- **認証情報保管**: Keychain (Security framework)
- **ビルド**: Xcode + Swift Package Manager
- **配布**: 自分のマシンに `xcodebuild` でビルドして `~/Applications/` に配置

## 重要な前提

- AWS SDK for Swift で `AWSS3` モジュールを利用
- マニフェストは JSON、ローカル DB は SQLite
- 全ての時刻は UTC、ISO8601 形式で保存
- ファイルパスは同期フォルダルートからの相対パス、POSIX 区切り（`/`）
- ハッシュは SHA-256（hex 小文字）
- Device ID は初回起動時にランダム生成し UserDefaults に保存
