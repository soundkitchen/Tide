# M3 実装ガイド（着手前の設計メモ）

> 本書は **M3 着手前の起点メモ** であり、まだ実装案の詳細を詰めきっていない。
> 個別タスクごとに最終仕様を決めながら実装する想定。
> M1 用の `05-IMPLEMENTATION-GUIDE.md` のような完成度の高いステップ分解ではない。

## 前提

- M1 / M2 は実装完了。詳細は `04-SYNC-LOGIC.md`、コードは `Tide/Core/SyncEngine.swift` 等を参照。
- 既存挙動を壊さないことが大前提。
- セキュリティベースライン (`security/`) と「会話で確定した実装決定」（`CLAUDE.md` 第 7 節）を必ず保つ。
- 新規実装には PathValidator / Logger プライバシー / SSE 等の現行ルールを継承する。

## M3 スコープ（`00-OVERVIEW.md` から）

1. 3-way merge による双方向同期
2. S3 Transfer Manager 統合（マルチパートアップロード、レンジダウンロード）
3. 中断・再開機能
4. `.syncignore` 対応
5. 帯域制御（オプション）

優先度の目安は **「マルチパート > `.syncignore` > 3-way merge > 中断再開 > 帯域制御」**。
詳細根拠は会話ログ参照。

---

## サブタスク A: マルチパートアップロード

### 目的
M1 で導入した「100 MB を超えたら `sync_log` にエラーを残してスキップ」(`Uploader.maxSizeM1`) を撤廃する。大きい写真・動画・アーカイブを同期できるようにする。

### 設計の出発点
- 公式の上位 API: `aws-sdk-swift-s3-transfer-manager`（別パッケージ）
  - 5 MiB のパートサイズが既定、自動分割 / 並列 PutPart / 失敗時の partial upload abort をハンドル
  - SHA-256 / Content-MD5 整合性は自前で組む（既存の `HashCalculator` を継承）
- マニフェスト側の変更:
  - `ManifestFileEntry.etag` は **マルチパート時は `<md5>-<part数>` 形式**。シングルパート時の挙動と挙動分岐が要る。`s3_version_id` は引き続き S3 が返したものを保持。
- ライフサイクルルール `tide-abort-incomplete-multipart` は既に投入済み（7 日後 abort）なので、失敗した multipart 残骸はコスト事故にならない。

### 影響範囲
- `project.yml` の packages に `aws-sdk-swift-s3-transfer-manager` を追加
- `Uploader.processUpload` を「サイズで分岐 → 100 MiB 以下なら従来パス、超ならマルチパート」に拡張
- `TideS3Client` にマルチパート用の薄いラッパを追加
- `security/medium.md` の **M5 (TOCTOU)** をこのタイミングで解消（ハッシュ計算と読み込みを 1 ストリームに統合）

### ユーザに事前に決めてもらいたい
- アップロードサイズ上限（M3 では撤廃 or 別途設定可能 UI を出すか）
- 失敗時のリトライ方針（ファイル単位 / パート単位 / リジューム可否）

### 受け入れ確認
- `~/TideSandbox/big.bin`（例: 500 MB）をマルチパートでアップロード可能
- ネットワーク切断 → 再接続でリジューム or 安全に失敗 → 再キュー
- マニフェストの etag フォーマットが S3 と一致
- 100 MB 以下のファイルは従来通り（リグレッションなし）

---

## サブタスク B: `.syncignore` 対応

### 目的
`HardcodedIgnoreRules` のハードコード除外に加えて、ユーザが `<syncRoot>/.syncignore` を置いて gitignore 構文で除外パターンを指定できるようにする。

### 設計の出発点
- gitignore 構文のサブセットをサポート: `*`, `**`, `?`, ディレクトリ末尾 `/`, 否定 `!`, コメント `#`
- ライブラリ: `Glob` 系を自前で書くか、`fnmatch(3)` を CryptoKit のように包むか
- `.syncignore` 自体は同期対象に含める？除外する？ → **同期対象に含めるのが慣例**（マニフェスト経由で他デバイスにも伝わる）
- 既存の `HardcodedIgnoreRules.shouldIgnore(relativePath:)` の前段に挟むか、置き換えるか

### 影響範囲
- `Tide/Core/IgnoreRules.swift` を拡張
- `FileWatcher` / `SyncEngine.performFullScan` / `ManifestReader` 等の除外判定経路
- `.syncignore` の変更検知 → リロード（FSEvents で拾える）

### ユーザに事前に決めてもらいたい
- `.syncignore` 自体を同期対象に入れるかどうか
- 既存ファイルが新たに除外パターンに該当するようになった時の挙動（S3 から削除する？残す？）

### 受け入れ確認
- `.syncignore` に `*.log` と書くと、新規 `*.log` がアップロードされない
- gitignore と挙動が一致する（ユーザの直感を裏切らない）

---

## サブタスク C: 3-way merge 形式化

### 目的
現状の M2 はテーブル化された単純ルール（`04-SYNC-LOGIC.md` の「競合解決（M2 の単純ルール）」）で動いている。これを **ベースバージョン / ローカル変更 / リモート変更** の 3-way 視点で形式化する。

### 設計の出発点
- ベースは「最後にローカル DB に記録された SHA」(`FileRecord.sha256`)
- 3 つの SHA を比較して 8 通りの分岐を整理
  - 3 つすべて同じ → スキップ
  - ローカルだけ変化 → upload
  - リモートだけ変化 → download
  - 両方が同じ方向に変化 → スキップ（fast-forward）
  - 両方違う方向に変化 → コンフリクト（M2 の rename ロジック）
- マニフェストエントリに「親バージョン」フィールドを増やすかは設計判断（増やすとマニフェストが膨らむが、より厳密にできる）

### 影響範囲
- `SyncEngine.reconcileRemoteEntry` の判定ロジック
- `Uploader.processUpload` 直前にも同等の判定が要るかも（並行更新検出）
- マニフェストスキーマ拡張（後方互換のため version up）

### ユーザに事前に決めてもらいたい
- マニフェストにベース SHA / parent version_id を増やすか
- 既存のテーブル方式から大きく挙動が変わらないことを優先するか、厳密性を優先するか

### 受け入れ確認
- 既存の M2 動作（特に conflict rename）と挙動が一致する
- 8 通りの分岐をすべてユニットテストで網羅

---

## サブタスク D: 中断・再開

### 目的
ダウンロード / アップロードが途中で中断した場合に、次回起動時に途中から再開する。

### 設計の出発点
- マルチパート（サブタスク A）の延長として実装するのが自然
- アップロード: 失敗パートだけ再 PutPart（s3-transfer-manager がある程度面倒を見る）
- ダウンロード: GetObject の Range ヘッダで途中バイトから取得
- 状態の永続化: `upload_queue` テーブルにパート進捗カラムを追加？ 新規 `transfer_state` テーブル？

### ユーザに事前に決めてもらいたい
- 進捗 UI を出すか（メニューバーの簡易バーで十分か）
- アプリ killed 時の挙動（再開 or 再アップロード）

---

## サブタスク E: 帯域制御（オプション）

### 目的
バックグラウンドで動作中に帯域を制限したい時のための上限設定。Settings で「アップロード上限 X MB/s」「ダウンロード上限 Y MB/s」を指定可能に。

### 設計の出発点
- aws-sdk-swift 側に直接の帯域制御 API があるか要調査
- 無ければ `URLSession` レベル / アップロード並列度の動的調整 / トークンバケットアルゴリズム
- 優先度は低い（個人利用想定）

---

## 共通タスク（M3 全体に共通する作業）

- マニフェストバージョン番号の bump（既存 `version: 1` を `2` に上げて、リーダ側で互換層を持つかどうか議論）
- セキュリティレビューの C3 後半 (`PutBucketPolicy` で HTTPS 強制)、H3（IAM Identity Center 検討）を必要に応じて並行で
- 動作確認用に `tmp/M3-動作チェックリスト.md` を切る運用は M1 / M2 と同じ

## 着手前の必読

- `CLAUDE.md`（特に「会話を通じて確定した実装決定」と「コミット前ドキュメント更新」の大原則）
- `security/README.md` の Status 表
- `docs/04-SYNC-LOGIC.md` の M2 セクション
- 直近のコミットログ（`git log --oneline`）
