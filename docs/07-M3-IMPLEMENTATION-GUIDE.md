# M3 実装ガイド（着手前の設計メモ）

> 本書は **M3 着手前の起点メモ** であり、まだ実装案の詳細を詰めきっていない。
> 個別タスクごとに最終仕様を決めながら実装する想定。
> M1 用の `05-IMPLEMENTATION-GUIDE.md` のような完成度の高いステップ分解ではない。

## 前提

- M1 / M2 は実装完了。詳細は `04-SYNC-LOGIC.md`、コードは `Tide/Core/SyncEngine.swift` 等を参照。
- 既存挙動を壊さないことが大前提。
- セキュリティベースライン (`security/`) と「会話で確定した実装決定」（`docs/08-IMPLEMENTATION-NOTES.md`）を必ず保つ。
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

## サブタスク A: マルチパートアップロード（実装済み）

> 実装日: 2026-06-02。**自前ラッパ方式**で実装した（当初案の `aws-sdk-swift-s3-transfer-manager`
> パッケージは採用せず＝新規依存なし）。FD/ハッシュ統合（M5）とパート進捗の制御を握りやすく、既存の
> 薄いラッパ流儀（`TideS3Client`）に揃うため。中断・再開は (a) セッション内のパート単位リトライのみ
> 実装し、UploadId 永続化・再起動またぎ再開・Range ダウンロード再開はサブタスク D（別チャンク）に分離した。

### 目的
M1 で導入した「100 MB を超えたら `sync_log` にエラーを残してスキップ」(`Uploader.maxSizeM1`) を撤廃する。大きい写真・動画・アーカイブを同期できるようにする。

### 実装（自前ラッパ）
- `TideS3Client` に AWSS3 の `createMultipartUpload` / `uploadPart` / `completeMultipartUpload` /
  `abortMultipartUpload` の薄いラッパと、`downloadToFile`（GetObject のボディを `ByteStream.readAsync`
  でチャンク・ストリーミング → tmp へ書込 + SHA-256 逐次計算）を追加。SSE-S3 は create 時に必ず付与。
- `MultipartUploader`: 単一 `NoFollowFileReader` から順次読込しつつ SHA-256 を逐次更新し、読み終えた
  パートを有界並列（最大 3）で UploadPart。読む順序＝ハッシュ更新順序を保つので全体ハッシュは正しく確定。
- アダプティブパートサイズ（`PartPlan`）: 目標パート数 9,000 基準値を `[5MiB, maxPartSize(64MiB)]` に
  クランプ（常駐メモリ抑制＝L11）、10,000 パートに収まらない超巨大ファイルのみ必要分まで partSize を上げる
  （MiB 境界切り上げで `partCount ≤ 10,000`）。シングル/マルチ分岐閾値 16 MiB。
- マニフェスト etag は S3 返値をそのまま格納（マルチパートは `<md5>-<partcount>`）。整合性は sha256 ベース。
- object metadata から `sha256` を外した（create 時点で未確定 ＆ 参照する経路が無い）。詳細は `02-S3-LAYOUT.md`。
- マニフェスト側の変更:
  - `ManifestFileEntry.etag` は **マルチパート時は `<md5>-<part数>` 形式**。シングルパート時の挙動と挙動分岐が要る。`s3_version_id` は引き続き S3 が返したものを保持。
- ライフサイクルルール `tide-abort-incomplete-multipart` は既に投入済み（7 日後 abort）なので、失敗した multipart 残骸はコスト事故にならない。

### 影響範囲（実績）
- `project.yml` は変更なし（自前ラッパのため新規パッケージ追加せず）
- `Uploader.processUpload` をサイズ分岐に改修（≤16MiB は単発、超はマルチパート）。`maxSizeM1` 撤廃
- `TideS3Client` にマルチパート薄ラッパ + `downloadToFile`（**サブ D-D3 で `streamObject` に置換済み**・下記 D3 参照）を追加。新規 `MultipartUploader` / `NoFollowFileReader` / `PartPlan`
- `security/medium.md` の **M5 (TOCTOU)** を解消（`O_NOFOLLOW` の単一 FD でハッシュ + 読込を統合）。`security/low.md` L9 も一括解消
- 大ファイルの **ダウンロード**も `downloadToFile`（→ D3 で `streamObject`）でストリーミング化（旧 200MiB インメモリ cap を撤廃。復元の round-trip を保つ）

### 確定した設計判断（ユーザ承認済み）
- アップロード上限は **1 ファイルあたり**（バケット総量ではない）。**UI 設定可能・既定 1GiB**・`-1`=無制限。`ConfigStore.uploadSizeLimitBytes`。
  上限超過は黙ってスキップせず `recentIssues` に明示 + `sync_log` error + キュー除去（リトライしない）。Settings で 1GiB 超を選ぶと課金注意を表示。
- 失敗時リトライ: **パート単位（セッション内、指数バックオフ 3 回）** + 既存のファイル単位リトライ（最大 5 回）。永続再開はサブD。

### 受け入れ確認（手動チェックリスト `tmp/M3-動作チェックリスト.md`・✅ 全項目消化済み 2026-06-07）
- `~/TideSandbox/big.bin`（例: 500 MB）を up → S3 → down で SHA 一致（round-trip）
- ネットワーク瞬断 → 失敗パートのみ再送で完走
- 上限超過ファイルが `recentIssues` に明示される（黙ってスキップしない）
- マニフェストの etag フォーマットが S3 と一致（`<md5>-<partcount>`）
- 16 MiB 以下のファイルは従来通り（リグレッションなし）

### レビュー指摘の据え置き（PR #1 のコードレビュー、将来タスク）
- **結合部の自動テスト（テスト負債）**: `MultipartUploader` は ✅ **解消（2026-06-04）**。`protocol MultipartUploadClient`（4 メソッド）を切って `TideS3Client` を適合させ、actor フェイク + 実一時ファイルで SHA 整合・パート分割・空 parts ガード・一時/恒久リトライ・abort を `MultipartUploaderTests` でユニット化した（リトライ遅延は `MultipartUploader.RetryPolicy` 注入で高速化）。`PartPlan`/`NoFollowFileReader`/`ConfigStore` の純粋ロジックは既にカバー済み。DL 経路は ✅ **解消（2026-06-04・サブ D-D3）**: `downloadToFile` を `streamObject` + `RangedDownloadClient` シームに置換し、`DownloaderTests`（実 DB + フェイク seam）で fresh/resume/etag 不一致/ネットワーク失敗保持/SHA 不一致/404 を網羅。
- **`uploadPartWithRetry` のエラー分類**: 現状あらゆるエラーを 3 回リトライする。認証エラー・`EntityTooSmall` 等の恒久失敗は即諦める分類を入れるとリトライ空振り（S3 API 課金含む）を減らせる（`security/low.md` L10 参照）。

---

## サブタスク B: `.syncignore` 対応（実装済み）

> 実装日: 2026-06-01。会話で 3 つの設計判断を確定して実装した（下記）。

### 目的
`HardcodedIgnoreRules` のハードコード除外に加えて、ユーザが `<syncRoot>/.syncignore` を置いて gitignore 構文で除外パターンを指定できるようにする。

### 確定した設計判断
- **構文**: gitignore の一般的サブセット — `*`, `**`, `?`, 先頭 `/` アンカー、末尾 `/` でディレクトリ限定、否定 `!`（再包含）、`#` コメント、空行。
- **既存ファイルの扱い（gitignore 純正）**: `.syncignore` のユーザパターンは**新規ファイルにのみ**適用する。
  既に同期済み（`FileRecord.lastSyncedAt != nil`）のファイルは触らない。S3 からも自動削除しない。
  → orphan も「誤爆で全消し」も起きない。バックアップから外したい時はローカル削除 → 通常の削除伝播で消す。
- **`.syncignore` 自体は同期対象に含める**: S3 経由で全デバイス・クリーンインストール復旧後にも除外設定が伝わる。
- **セキュリティ不変条件**: `HardcodedIgnoreRules`（機密網）は常に最優先。`.syncignore` の否定 `!` で `.env` 等を再包含できない。
  「既存は触らない」緩和はユーザパターンにのみ適用し、ハードコード除外には適用しない。

### 実装
- 新規 `Tide/Core/SyncIgnoreMatcher.swift`: 不変・`Sendable` な値型。グロブ → トークン列へコンパイルし
  （ユーザ正規表現は受けない）、照合は **reachable-set DP**（`O(パターン長 × パス長)`）で行う。ファイルサイズ上限 256 KB / パターン数上限 10,000。
  **ReDoS は構造的に解消済み（F1 / L8、2026-06-04）**: 旧来は生成正規表現を `NSRegularExpression`（ICU = バックトラッキング）で照合していたため `*a*a*…` 系で破滅的バックトラッキングが起こり得たが、`NSRegularExpression` を廃して線形時間照合に置換した（バックトラッキング自体が存在しない）。
  前段の上限（パターン長 `maxPatternLength` / ワイルドカード数 `maxWildcardsPerPattern` / 照合入力長 `maxMatchPathLength`）は ReDoS 防御の load-bearing ではなくなったが、防御的サニティ上限として保持。
- 新規 `Tide/Core/IgnoreDecision.swift`: 純粋関数 `shouldSkip(relativePath:isAlreadyTracked:matcher:)`。
  判定順: ① ハードコード（常に）→ ② `.syncignore` 自身（決して除外しない）→ ③ ユーザパターン∧未追跡 → スキップ。
- `SyncEngine`: `ignoreMatcher` を保持。`reloadIgnoreMatcher()` で `<syncRoot>/.syncignore` を安全に読込
  （symlink 追従しない / `PathValidator.resolveSafely`）。`start()` / リモート pull 末尾 / `.syncignore` 変更検知で再読込。
  統合点は `performFullScan` / `processEventToQueue` / `reconcileRemoteEntry` の 3 経路。
  **（#64・2026-07-21 更新: `reloadIgnoreMatcher()` の呼び元はリモート pull 末尾のみに縮小。起動時・ローカル
  変更時はフルスキャンの走査副産物 + 変更 1 枚のインプレース patch へ移行 — `docs/08`「フルスキャンの単一走査化」節）**
- `.syncignore` 変更は FSEvents で拾い、再読込 + フルスキャン再評価。`.syncignore` 自身もアップロード（同期）。
- `SettingsWindow`: 現行 `.syncignore` パターンを閲覧表示（編集は将来）。
- 既定テンプレート: `SyncIgnoreMatcher.defaultTemplate`（`node_modules/` 等）を **新規バケットのセットアップ時のみ** `AppEnvironment.completeSetup` で `<syncRoot>/.syncignore` に自動生成。既存バケット参加時は競合回避のため作らない。`.git/` は含めない（同期対象のまま）。
- テスト: `SyncIgnoreMatcherTests`（意味論全件 + 線形時間回帰 `testPathologicalPatternMatchesInLinearTime` + 旧 regex との differential fuzz `testLinearMatcherMatchesReferenceRegex`）/ `IgnoreDecisionTests`。

### ネスト `.syncignore`（[#27] / C1・✅ 2026-06-25 追加）
- **ディレクトリごとの `.syncignore`（git 風の階層的オーバーライド）に対応**。同期ルート配下の全 `.syncignore` を収集し、対象パスの祖先ディレクトリの `.syncignore` を**浅い→深い順**に合成して判定する（深い層が浅い層を上書き＝単一ファイル内の last-match-wins を階層へ拡張。マッチ無しの層は上位層の判定を維持）。各層には「その層のディレクトリからの相対パス」を渡すので、パターンはそのディレクトリにアンカーされる（先頭 `/` も当該ディレクトリ基準）。
- 実装: `SyncIgnoreMatcher.evaluate` を三状態（`unmatched`/`ignored`/`included`）化し、新 `LayeredSyncIgnore`（`[dir 相対パス: SyncIgnoreMatcher]` を束ねる `Sendable` 値型・`SyncIgnoreMatcher.swift` 内）が層合成を担う。`IgnoreDecision.shouldSkip` は `LayeredSyncIgnore` を受け取る。自己保護はネスト `.syncignore`（末尾 `/.syncignore`）へ拡張（共有判定 `IgnoreDecision.isSyncignoreFile`）。
- **キャッシュ戦略 = 変更時フル再構築**: in-memory の dir→matcher 辞書がキャッシュ本体で**評価ホットパスは I/O ゼロ**（祖先 dir を辞書引きするだけ）。辞書の再構築（`SyncEngine.loadLayeredIgnore` のツリー走査）は起動時と実際の `.syncignore` 変更時のみ — ローカルは FSEvents（`isSyncignoreFile`）、リモートは pull が `.syncignore` を触ったときだけ（過大近似で取りこぼし防止）。定常 pull / 通常ファイル編集ではツリーを再走査しない。走査は symlink 非追従・機密網ディレクトリ丸ごとスキップ・`LayeredSyncIgnore.maxFiles`(1000) で有界。**（#64・2026-07-21 更新: 起動時・ローカル変更時の再構築はフルスキャンの走査副産物（単一走査）+ 変更 1 枚のインプレース patch へ移行。`loadLayeredIgnore` は pull 末尾専用に残置 — `docs/08`「フルスキャンの単一走査化」節）**
- Settings はディレクトリ単位にグルーピング表示（`LayeredSyncIgnore.directoryGroups`）。
- テスト: `SyncIgnoreMatcherTests`（三状態 + ネスト/オーバーライド/否定再包含/相対アンカー/グループ並び）/ `IgnoreDecisionTests`（ネスト自己保護・機密網優先・深い層再包含）。

### 既知の制限 / 将来タスク
- 親ディレクトリが除外された配下のファイルを `!` で再包含する gitignore の挙動は厳密には再現しない（同一階層・別階層の否定は正しく動く）。
- ~~**ReDoS の構造的解消（F1 / L8）は将来タスク**~~ → ✅ **完了（2026-06-04）**。`NSRegularExpression` を廃し、グロブをトークン列へコンパイルして reachable-set DP で評価する線形時間照合へ置換した（`**` / 否定 / アンカー / dirOnly のセマンティクスを移植）。`SyncIgnoreMatcherTests` の既存意味論テストを回帰オラクルに維持し、旧 regex 実装との differential fuzz（`testLinearMatcherMatchesReferenceRegex`）で同値を確認。
- マッチングは case-sensitive（gitignore 既定）。
- `ManifestReader` には ignore 判定を入れず、ダウンロード可否は `reconcileRemoteEntry` で gate する（削除検出が完全な remoteMap に依存するため）。

### 受け入れ確認
- `.syncignore` に `*.log` と書くと、新規 `*.log` がアップロードされない。`!important.log` で再包含される。
- パターン追加前から同期済みのファイルは同期継続（S3 から勝手に消えない）。
- `.syncignore` 自体が S3 にアップロードされる。
- `!.env` を書いてもハードコード除外が勝ち、`.env` は同期されない。

---

## サブタスク C: 3-way merge 形式化 — ✅ 実装済み（2026-06-04）

### 目的
M2 の単純ルール（`04-SYNC-LOGIC.md`「競合解決」）を **ベース / ローカル / リモート** の 3-way 視点で形式化し、判定を副作用から切り離してユニットテストで固める。

### 実装
- 新規 `Tide/Core/ThreeWayMerge.swift`: 純粋関数 `decide(base:local:remote:) -> MergeDecision`（`IgnoreDecision`/`PartPlan`/`ConflictNamer` と同じ純粋 enum + static パターン）。`MergeDecision` は `.download` / `.localMatchesRemote` / `.conflictThenDownload` / `.deleteLocal` / `.keepLocalRemoteDeleted` / `.noop`。
- ローカル状態は `LocalState`（`.absent` / `.unreadable` / `.present(sha)`）で表現。「不在」と「在るが SHA 計算不能」を区別し、**pull 側の unreadable を無確認上書きから保守的なコンフリクト退避へ厳格化**（PR #3 レビュー指摘 1。旧 M2 はここを download に倒していた）。これで unreadable の意味論も `decide()` に集約・テスト可能。
- `SyncEngine.reconcileRemoteEntry`（pull 側）と `Downloader.applyRemoteDeletion`（削除側）を `decide()` 経由に整理。安全ゲート（`PathValidator` / symlink 拒否 / ignore 判定）と I/O は維持。
- 新規 `TideTests/ThreeWayMergeTests.swift`: `base`(nil/"A"/"B") × `local`(.absent/.unreadable/.present) × `remote`(nil/SHA) の分岐代表ケース + M2 表対応 named ケース + unreadable ケースで全分岐網羅。

### 確定した設計判断
- **ベース = `FileRecord.sha256`（ローカル DB）**。マニフェストにベース SHA / parent version_id は**追加しない**（version dispatch 基盤が無く、旧クライアントが未知フィールドを round-trip で落とすリスク。形式化に schema 拡張は不要）。`ManifestShard.version`/`ManifestIndex.version` も 1 のまま。
- **挙動は M2 と 1:1 一致**を優先（厳密性のための挙動変更はしない）。`decide()` の各分岐は旧 reconcile/applyRemoteDeletion の分岐と等価（`04-SYNC-LOGIC.md` の表参照）。
- **アップロード側の並行更新検出はスコープ外**（下記の既知の制限）。`Uploader.processUpload` は変更していない。

### 受け入れ確認（達成）
- 既存 M2 動作（特に conflict rename・リモート削除の温存条件）と挙動一致。
- 全分岐を `ThreeWayMergeTests` で網羅（`make test` 緑）。

### 既知の制限 / 将来サブタスク
- **アップロード側の last-writer-wins ギャップ（✅ 解消済み 2026-06-23・Issue #25 / A・M3 ではスコープ外だった）**: 競合検出は当時 pull/削除側のみだった。同一ベースから 2 台が編集すると後勝ちでマニフェストが上書きされ、先に上げた側は次回 pull で「local == base＝未編集」判定で相手版を取り込み、ローカル編集がワーキングコピーから消えていた（S3 バージョン履歴には残る）。**v0.2.0 で対称化**: `ThreeWayMerge.decideUpload` + `Uploader.ManifestUpdater.updateFileEntry`（書込シームでリモートマニフェスト読み）+ `SyncEngine.resolveUploadConflict`（リモート版が正規パスで勝つ・versionId 指定取得）。詳細は `docs/04-SYNC-LOGIC.md` /  `docs/08-IMPLEMENTATION-NOTES.md`「アップロード側の並行更新検出」。
- **配線部（`MergeDecision` → 実 I/O）が未結合テスト**（PR #3 レビュー指摘 2）: `decide()` の純粋ロジックは全分岐網羅したが、「`.deleteLocal` が削除+DB削除+log」「`.conflictThenDownload` が rename→download」等の switch マッピングを検証する結合テストは無い（switch の取り違えを回帰検出できない）。`Downloader.applyRemoteDeletion` は S3 を使わないので、`MultipartUploadClient` と同様に `Downloader` へ最小 S3 シームを切れば temp DB + temp syncRoot で削除側の結合テストが可能。重いので別サブタスクに据え置き。

---

## サブタスク D: 中断・再開（✅ 実装済み 2026-06-05）

### 目的
ダウンロード / アップロードが途中で中断した場合に、次回起動時に**ファイル内の途中から**再開する。
`upload_queue` によるファイル単位の再開（再起動後に同じファイルを再処理）は既存。D が足すのは「5GB の 80% まで上げてから kill された時にゼロから再送しない」というファイル内再開。

### 確定した設計判断（ユーザ承認済み）
- **スコープ = アップロード＋ダウンロード両方**。
- **状態の永続化 = 新規 `transfer_state` テーブル**（`upload_queue` へのカラム追加ではない）。
  ダウンロードは `upload_queue` を使わない（pull/reconcile 駆動）ので、両方向を 1 機構で扱える `transfer_state` を採用。
- **kill 時の挙動 = 再開**。checkpoint（パート完了ごと / Range オフセット）を再開起点にし、再送パートは UploadPart 冪等で上書き安全。SHA は streaming で確定するので、再開時は未処理分だけネットワークし既処理分はローカル再読込でハッシュ復元、最後に必ず期待 SHA と突合（不一致＝破棄してフル再送）。
- **進捗 UI = メニューバーのポップオーバーウィンドウ（`MenuBarContent`）に「Transferring」セクション**。独自の極小バーは作らない。

### 実装ステップ（feature/m3-subd-resume・段階コミット）
- **D1 スキーマ＋ストア（✅ 実装済み）**: migration v2 `transfer_state` / `TransferStateRecord`(GRDB) / `TransferStateStoring` プロトコルシーム + `TransferStateStore`（GRDB 実装）+ `TransferStateStoreTests`（実 DB）。挙動変更なし。スキーマ詳細は `docs/03-LOCAL-DATABASE.md`。
- **D2 アップロード再開（✅ 実装済み）**: `UploadCheckpointStore` シーム（`TransferStateStoring` から分離）を `MultipartUploader.ResumeContext` 経由で注入。mtime/size 一致なら前回 UploadId・完了パート・partSize を引き継いで未送分だけ送り（既送分も読み順に hash 更新して全体 SHA を復元）、不一致なら古い MPU を best-effort abort してフル再開。パート完了ごとに `recordCompletedPart` で checkpoint、成功で `clearUpload`。**失敗時の方針**: `resume` 指定時は abort も clear もせず MPU と進捗を保持（次回のファイル単位リトライ／プロセス kill 後の次回起動で再開）。恒久失敗の残骸はライフサイクル tide-abort-incomplete-multipart（7日）と D5 起動時掃除に委ねる。`resume` なしの呼びは従来どおり失敗時 best-effort abort（後方互換）。`MultipartUploaderTests` にフェイク checkpoint で 4 ケース追加（新規永続→クリア / 既送スキップ / ファイル変化でフル再開 / 恒久失敗で保持）。
- **D3 ダウンロード再開（✅ 実装済み）**: 旧 `downloadToFile` を Range 対応の `TideS3Client.streamObject(key:rangeStart:sink:)` に置換し、`RangedDownloadClient` シーム（`TideS3Client` 適合 + テストでフェイク差込）を新設。`Downloader` は決定的 tmp（`dl-<sha(path)>.part`）を使い、`transfer_state` の download 行が現エントリ etag と一致し tmp が `0 < size < entry.size` なら既存プレフィクスを読み直して hash に前置きし `Range: bytes=size-` で再開、無効なら作り直してフル取得。M7 の DoS ガードは sink で受信累積長を `entry.size` と突合（超過は破棄）。ネットワーク失敗は部分 tmp + 行を保持して次回再開、etag/SHA 不一致・サイズ超過・404 は破棄して仕切り直す。`DownloaderTests`（実 DB + フェイク seam）で fresh/resume/etag 不一致/ネットワーク失敗保持/SHA 不一致/404 を網羅＝DL 経路のテスト負債も返済。
- **D4 進捗 UI（✅ 実装済み）**: `SyncEngine.activeTransfers: [TransferProgress]`（@Observable）を追加。off-main の `Uploader`/`Downloader` が `@Sendable` な `TransferProgressReporter`（`begin`/`update`/`end`）を発行し、`SyncEngine` が `Task { @MainActor }` で `applyProgress` に集約（到着順は前後し得るので update は既存エントリの増加方向のみ適用、(path, direction) で一意）。アップロードはパート完了ごと（既送分も即時加算）、ダウンロードは ~4MiB ごとに coalesce。`MenuBarContent` のポップオーバーに「Transferring」セクション（方向アイコン + ファイル名 + % + `ProgressView`）を追加。新規 xcstrings キー `"Transferring"`（`extractionState:"manual"`）。`stop()` で `activeTransfers` をクリア。視覚確認は D5 の動作チェックリストで実機実施。
- **D5 ドキュメント＋セキュリティ＋掃除（✅ 実装済み）**: `SyncEngine.start()` 冒頭で `pruneOrphanTransfers()`（キュー/プル開始前に awaited＝再開ロジックと競合させない）。ローカルファイルの消えた upload 行は宙ぶらりんの MPU を best-effort `abortMultipartUpload` して削除、tmp の消えた download 行は削除、両方向とも 7 日より古い行は失効扱い（S3 `tide-abort-incomplete-multipart` と歩調を合わせる）。セキュリティは `security/low.md` L12（攻撃面レビュー＝Range 注入なし / tmp_path 再計算照合 / 再開時 symlink 破棄ガード / SHA ゲート / オーファン掃除）。受け入れは `tmp/M3-動作チェックリスト.md`（大ファイル round-trip・kill→再開 up/down・進捗 UI を実機で確認後に削除）→ **✅ 全項目消化済み（2026-06-07・チェックリストは運用どおり削除）＝サブタスク D 完了**。消化中に発見した項目（L6 実害化＝torn-write アップロード／prune clear 分岐の `invalidateShardCache` 漏れ（✅ 修正済み 2026-06-07・下記）／毎起動再アップロード（✅ 修正済み 2026-06-08・mtime 精度不一致 + SHA ゲート未実装が原因。`docs/08-IMPLEMENTATION-NOTES.md`「mtime の不変条件」 / `docs/09-DEFERRED.md` と `docs/04-SYNC-LOGIC.md` 実装ノート参照））は `docs/09-DEFERRED.md` と `security/low.md` L6 に記録。

### PR #4 レビュー反映（2026-06-05）
soundkitchen のレビュー（ブロッカー無し）を受けて 4 点を対応、2 点を据え置き。
- **#1 配線**: `Downloader` のネットワーク失敗 catch で `recordDownloadProgress(total)` を呼び、`bytes_done` を最新化＋`updated_at` を前進。これで本番未使用だった同メソッドが意味を持ち、`pruneOrphanTransfers` の 7 日 stale 判定が「実活動」を反映する（進捗のある tmp を誤って消さない）。
- **#3 symlink 追従窓**: fresh の tmp 書込を `Downloader.openTmpForWriting`（`O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`）へ。旧 `removeItem`→`createFile` の TOCTOU を解消し、アップロード側 `NoFollowFileReader` と対称化。
- **#4 空 etag ガード**: `ManifestFileEntry.etag` は `s3Etag ?? ""` で空になり得るので、空のときは再開 etag 照合が no-op になる。空 etag では resume せずフル取得に倒す（`!entry.etag.isEmpty` 条件）。
- **#6 進捗集約のテスト**: `applyProgress` を純粋関数 `TransferProgress.reduce` に切り出し、`TransferProgressTests` で begin/update（増加方向のみ）/end と out-of-order（end 後の遅延 update で復活しない等）を固定。
- **据え置き（Low/nit）**: #2 complete 直後クラッシュの stale UploadId（`NoSuchUpload` 空振り。正しく塞ぐには `HeadObject` 復旧が要る）、#5 進捗 begin/end の Task 再順序ゴースト（純粋 reducer では塞げない・ほぼ起きない）。docs/09-DEFERRED.md に記録。

### 受け入れテストで発見・修正（2026-06-05）
実機チェックリスト消化中に **重大なダウンロード破損バグ**を発見し修正した。
- **症状**: kill→再開のダウンロードで、復元ファイルが `entry.size` より過大（全ゼロのテストファイルで +4〜5MB）になり、しかも整合性ゲートをすり抜けて commit → 監視経由で再アップロードされ**リモートのマニフェストまで汚染**した。
- **原因**: リモート pull の並行。再入ガード `remotePullInFlight` は `triggerRemotePullSafely`（poll/wake/network）にしか無く、**`SyncEngine.start()`（起動時）と「S3 から取得」ボタンが `triggerRemotePull()` を無防備に直呼び**していた。起動時 pull と初回 network-up 等が並行すると、同一ファイルを 2 つの reconcile が**決定的 tmp `dl-<sha(path)>.part`（ファイル別ロック無し）へ並行追記** → 過大化。各 DL は自分の論理 SHA でゲート通過、`updateDBEntryAfterDownload` が `entry.size` を記録するので見逃された。**普通の起動操作で再現**（ユーザ操作不要）。
- **修正（多層）**: (1) **pull の単一ゲート化**＝再入ガードを `triggerRemotePull()` 本体へ移設し、start()・ボタン・poll/wake/network の全経路を直列化（@MainActor で check→set 間に await が無く安全）。(2) **`Downloader.download` の commit 前に実 tmp サイズ == `entry.size` を検証**し不一致は破棄（論理 `total` でなく実ファイルサイズを突合する防御）。
- **検証**: 修正版で kill→再開すると復元ファイルが size+sha ともマニフェスト記載値にぴったり一致・過大化なしを実機確認。`make build && make test` 通過。
- **関連で発見した別バグ（✅ 修正済み）**: 中断したダウンロードが**再起動だけでは自動再開しなかった**（`ManifestReader` が DL 完了前にシャードを `shard_state` へ「取得済み」記録するため、次回 pull が当該シャードをスキップ＋未完で DB レコードも無い→ reconcile されず `Downloader.download` に到達しない）。Range 再開機構自体は正しいが到達経路が無かった。**修正**: `SyncEngine.pruneOrphanTransfers` で再開可能な download 行（tmp あり・新しい）の path のシャードの `shard_state` を invalidate し、起動 pull に再取得→reconcile→Range 再開させる（既存機構の再利用）。実機で「再起動のみで自動 Range 再開・SHA 一致」を確認。docs/09-DEFERRED.md 参照。
- **セッション中の再 arm（PR #9 レビュー ②・✅ 修正済み 2026-06-07）**: 上記の再 arm は当初**起動時 prune でのみ**走り、セッション中に DL がネットワーク断等で失敗すると、シャードがリモートで変化するか再起動するまで取り残された。**修正**: sentinel 化を `LocalDatabase.invalidateShardCache(forPath:)` に共通化し、`Downloader.download` のネットワーク失敗 catch（部分 tmp を保持する resumable 失敗）からも呼ぶ。次の poll/wake/network-up pull が再取得→reconcile→Range 再開する。破棄系（SHA/サイズ不一致・404）は決定的に再失敗するため再 arm しない（`DownloaderTests` で両スコープを回帰固定）。
- **手動 pull の coalescing（PR #9 レビュー ④・✅ 修正済み 2026-06-07）**: 単一ゲート化の副作用で、pull 進行中の手動「S3 から取得」が無反応・無表示でドロップされていた。**修正**: 手動（`reason == .manual`）のみ pending 化して現 pull 終了後にもう 1 周（`.manualCoalesced`）。ゲートフラグは `isRemotePulling`（@Observable・`private(set)`）に改名・公開し、ボタンは pull 中スピナー + 「Pulling…」表示（enabled のまま＝押下が coalescing の入口）。PR #10 レビュー反映で coalesced ラウンドに stop/cancel ガード（Low-1）と `reason` の `SyncEngine.PullReason` enum 化（Low-2）を追加。`docs/04-SYNC-LOGIC.md` トリガー節参照。
- **prune clear 分岐の invalidate 漏れ（受け入れテスト §6-2 で発見・✅ 修正済み 2026-06-07）**: 上記の起動時再 arm は **resumable な download 行（tmp あり・新しい）だけ**を invalidate しており、tmp が消えている（または stale な）行の clear 分岐は `transfer_state` 行を削除するだけだった → FileRecord 無し + `shard_state` は実 etag のままで、当該ファイルはシャードがリモートで変化するまで**永久に再 DL されない**。**修正**: clear 分岐でも行を落とす**前に** `invalidateShardCache` を実行（resumable 分岐と対称）。invalidate 失敗時は行を消さず continue（行が残れば次回起動の prune が再試行＝自己回復。先に行を消すと取り残しが再発するため順序が本質）。あわせて prune 本体を `SyncEngine.pruneOrphanTransfers(db:store:syncRoot:now:abortUpload:)`（`nonisolated static`・依存注入）へ切り出し、`TransferPruneTests`（実 DB + abort フェイク）で clear（tmp 消失/stale）・resumable・upload 全分岐の「分岐 → 実 I/O」配線を回帰固定（`security/low.md` L12 の「prune 結合テスト未整備」据え置きも解消）。PR #11 レビュー反映で `default:` 分岐（未知 direction・到達不能）にも同ガードを適用して不変条件を全分岐化（Low-1）、clear 成否どおりのログ出し分け（nit-2）。Low-1 のテスト追加で旧 `default:` 分岐は direction フィルタの都合で実際には何も消せていなかったことも判明し、`TransferStateStore.clearUnknownDirections(path:)` を新設して除去を実効化。据え置き nit（invalidate 失敗経路のテスト・stale tmp litter のトレードオフ）は `docs/09-DEFERRED.md` に記録。

---

## サブタスク E: 帯域制御（✅ 実装済み・2026-06-10）

### 目的
バックグラウンドで動作中に帯域を制限したい時のための上限設定。Settings で「アップロード上限 X MB/s」「ダウンロード上限 Y MB/s」を独立に指定できる（既定は無制限）。

### 実装
- **方式はトークンバケット**。aws-sdk-swift の高レベル `S3Client` には公開の帯域制御ノブが無い（`S3ClientConfiguration` にレート上限の設定は無く、URLSession/CRT に委譲して全速送信する）ため、docs の出発点どおりアプリの送受信フィード層で律速する（SDK 非依存・テスト可能）。
- **`Tide/Core/RateLimiter.swift`**: レート計算は純粋関数 `TokenBucket`（`StabilityCheck`/`PartPlan` と同じパターンで `RateLimiterTests` が全分岐網羅）、`RateLimiter` actor が単調時計（`DispatchTime`）と `Task.sleep` を担当。**予約（負残高許容）方式**で、`acquire(n)` は `n` を即座に残高から差し引き「残高が 0 以上へ回復するまでの待ち秒」だけ待つ。先に差し引くので並行 acquire でも公平（到着順で後続は先行分の負債も含めて待つ）に総スループットが収束する。`rate <= 0` は無制限（即返る）。`n > burst` でもデッドロックしない（比例待ち）。バーストは「アイドル中に貯まるトークン上限 = 1 秒ぶん」で抑える。
- **スロットル点**（実データフローに対応）:
  - マルチパートアップロード（`MultipartUploader.upload`）: 各 `uploadPart` をスケジュールする前に `await limiter.acquire(part.count)`。
  - ダウンロード（`TideS3Client.streamObject` の async 読みループ）: 各チャンクを `sink` へ渡す前に `await limiter.acquire(chunk.count)`。読込を遅らせると TCP フロー制御でサーバ送出も自然に絞られる。
  - 単発アップロード（`putObject`、≤16MiB）: Data 一括なので PUT 前に `acquire(size)`（平均レートで律速・粒度は粗いが個人利用では十分）。
- **共有リミッタ**: 同時並行転送（複数ファイル並行 UL/DL ＋ マルチパートのパート並列）が **`SyncEngine` 保持の 1 インスタンス**（upload 用／download 用）を共有して初めて合計が上限に収まる。`Uploader.uploadLimiter` / `Downloader.downloadLimiter` / `streamObject(limiter:)` へ注入する。
- **レートは config から周回ごとに更新**（`SyncEngine.refreshBandwidthLimits()` を runQueueLoop・performRemotePull の冒頭で呼ぶ＝`uploadSizeLimitBytes` と同じ「都度読み直し」流儀で Settings 変更が次の転送周回で効く）。
- **マニフェスト・シャード・index 等の小さなメタデータ PUT/GET は律速しない**（file 本体 `files/*` のみ）。
- **Settings UI**: `SettingsWindow` の「Bandwidth」セクションに「No upload/download bandwidth limit」トグル＋ MB/s スライダ（1〜100・1 刻み・トグル off で表示）。`uploadSizeLimitBytes` と同じく `@State` + `onAppear`/`onChange` の write-through。`ConfigStore.uploadBandwidthBytesPerSec` / `downloadBandwidthBytesPerSec`（bytes/sec、`<= 0`=無制限・既定 `-1`）。MB/s は decimal（1 MB/s = 1,000,000 bytes/s）。新規 xcstrings キーは `extractionState:"manual"`。

### 実機検証（2026-06-10・バケット `dev-tide`・上限 5 MB/s）
実 S3 で実効スループットが上限に収まることを確認した（ユニットテストはバケット計算のみ網羅するため）。uplink は無制限時 ~30–50 MB/s。
- **アップロード**: 150MiB を 35.6s で完了＝実効 4.41 MB/s（gross。デバウンス等を引いた転送のみは ~4.7 MB/s）。無制限なら数秒で終わるところが律速された。
- **ダウンロード**: 同 150MiB を起動時 pull で 31.8s＝実効 4.95 MB/s（≈上限）。
- いずれも**ローカル == S3 の SHA-256 が一致**（スロットル下でもマルチパート／Range・ストリーミングの内容は完全）、残置マルチパートなし、削除は delete marker 経由で伝播。

### 既知の制限 / 将来タスク
- 単発 PUT（≤16MiB）は本体を一括送出するため、acquire は送出**前**にまとめて待つ＝粒度が粗い（瞬間的には設定 MB/s を超え得るが平均は収束）。気になるなら将来 `putObject` をチャンク送出（multipart 同様）に寄せる。
- マルチパートの `acquire(part)` はパートにつき 1 回。`uploadPartWithRetry` の瞬断再送（最大 3 回・同 body）は再 acquire されず律速を外れる（PR #15 レビュー nit-1）。リトライは稀＆個人利用想定で実害は小さいため現状維持。厳密にするなら acquire を再送ループの内側へ寄せる（actor 共有の粒度が変わる点に注意）。
- マルチパートも「パート単位」での律速（acquire はパートをスケジュールする前）。partSize（5〜64MiB）粒度なので低レートだとバースト的だが平均は収束する。

---

## 共通タスク（M3 全体に共通する作業）

- マニフェストバージョン番号の bump（既存 `version: 1` を `2` に上げて、リーダ側で互換層を持つかどうか議論）
- セキュリティレビューの C3 後半 (`PutBucketPolicy` で HTTPS 強制) → ✅ **解消済み（2026-06-23・Issue #26 / B・M3 ではスコープ外だった）**。`enforceTLSBucketPolicy()` で `aws:SecureTransport=false` Deny を冪等適用（`security/critical.md` C3 / `docs/09`）。H3（IAM Identity Center 検討）は引き続き据え置き
- 動作確認用に `tmp/M3-動作チェックリスト.md` を切る運用は M1 / M2 と同じ

## 着手前の必読

- `CLAUDE.md`（特に「会話を通じて確定した実装決定」と「コミット前ドキュメント更新」の大原則）
- `security/README.md` の Status 表
- `docs/04-SYNC-LOGIC.md` の M2 セクション
- 直近のコミットログ（`git log --oneline`）
