# 🟢 Low / Hardening

## L1. App Sandbox 無効

**Status:** ✅ Fixed (2026-07-02・M5 Phase 2) — App Sandbox を有効化（`project.yml` entitlements: `com.apple.security.app-sandbox` + `files.user-selected.read-write` + `network.client`）。同期フォルダへのアクセスは security-scoped bookmark で永続化: セットアップ時（`AppEnvironment.completeSetup`）に発行して `ConfigStore.syncRootBookmark` へ保存（2026-05-24 に死蔵キーとして削除した同名キーの本実装）、起動時（`resolveSyncRootAccess`）に解決して scoped アクセスを開始・stale なら再発行。bookmark 欠落/失効（サンドボックス化前からのアップグレード）は起動時に NSOpenPanel で一度だけ再許可を取り、**設定済みフォルダと同一実体（`PathValidator.isSameFileSystemObject` = volume + file id）でない選択は拒否**する（別フォルダを黙って受けると既存 DB との突き合わせで大量の削除誤検出→リモート削除伝播を起こしうるため。パス文字列等値でなく同一性判定なのは、bookmark がリネーム/移動をファイル ID で追跡するため — リネーム時は `syncRootPath` を追随更新し、パネルは出さない。PR #49 レビュー #2）。File Provider 拡張（M5 Phase 3〜）はサンドボックス必須のため、その前提を app 側で先に整えた。

**該当箇所:** `project.yml` entitlements / `Tide/App/AppEnvironment.swift` `resolveSyncRootAccess` `requestSyncRootAccessViaPanel` `completeSetup` / `TideCore/Storage/ConfigStore.swift` `syncRootBookmark`

Hardened Runtime は有効だが、App Sandbox は無効。直配布 + Notarize 前提なら受容可能だが、サンドボックスを将来検討する場合は `tide.syncRootBookmark` の死蔵キー（`ConfigStore.swift:11`, `64`）からも分かるように、security-scoped bookmark 取得 → 永続化 → 再構築のフローが必要。今のコードでは bookmark は実際には保存していない（コード断片だけ残った "intent" 状態）。

---

## L2. 機密ファイル除外パターンが弱い

**Status:** ✅ Fixed (2026-05-24) — `HardcodedIgnoreRules` を拡張: `.env` / `.envrc` / `.netrc` / `.npmrc` / `.pgpass` / `.aws` / `.ssh` / `.gnupg` / `.kube` / `.docker` / `.gitconfig` / `id_rsa` / `id_ed25519` / `credentials` を exactNames、`.env.` を prefixPatterns、`.pem` / `.key` / `.p12` / `.pfx` / `.keystore` を新設の suffixPatterns に追加。`SetupWizardWindow.validateSyncRoot` で home / Library / System / Applications 配下の選択を警告。

**該当箇所:** `Tide/Core/IgnoreRules.swift`

`HardcodedIgnoreRules` は `.DS_Store` 等 OS の雑多ファイルのみ。**`.env`, `.envrc`, `id_rsa`, `id_ed25519`, `.npmrc`, `.aws/`, `*.pem`, `*.key`** などの「明らかな秘匿ファイル」も既定除外推奨。`SetupWizardWindow` は「`.git/` も含まれます」とだけ明示しているが、ユーザがホームディレクトリを選んだら破滅する。`validateSyncRoot` でホーム直下や `/Library`、`/Users/.../Library` を警告する強化を。

---

## L3. `openSyncFolder` に渡される URL の検証

**Status:** ✅ Fixed (2026-05-24) — `openSyncFolder` で `path.isEmpty` チェックと `FileManager.fileExists(atPath:isDirectory:)` でディレクトリ確認をしてから `NSWorkspace.shared.open` を呼ぶように修正。

**該当箇所:** `Tide/UI/MenuBarContent.swift:162-165`

```swift
NSWorkspace.shared.open(URL(fileURLWithPath: path))
```

`path` は ConfigStore 由来でユーザ入力。`URL(fileURLWithPath:)` は `/...` 以外でも何かしらの URL を生成し、`NSWorkspace.open` は登録ハンドラを起動する。実害は小さいが `FileManager.fileExists(isDirectory:)` で確認してから開くべき。

---

## L4. `bucketSetupLog` / errorMessage に `String(describing: error)`

**Status:** ✅ Fixed (2026-05-24) — H2 と一括で対応。OS Log は `privacy: .private` に揃え、UI 側の `secretAccessKey` は SecureField で受けて成功時に即 `""` で参照を切る (L7 と連動)。SetupWizard のエラー文には `accessKeyId` の先頭文字を含めうるが、SecureField で受けた値は誤って画面表示されないことを Swift の型レベルで担保している。

**該当箇所:** `Tide/UI/SetupWizardWindow.swift:243, 262, 287, 302, 323`

ウィザード初回投入直後のエラー文には、AWS SDK が `accessKeyId` の先頭文字を含めるケースがある。少なくとも SecureField で受けた `secretAccessKey` を**間違っても画面に出さない**ことを単体テストで担保するとよい。

---

## L5. `Insecure.SHA1` 使用箇所

**Status:** ✅ Fixed (2026-05-24) — `ManifestSharding.shardId` に「セキュリティ用途ではなく、ハッシュ空間にばらまくための用途」と明示するコメントを追加。

**該当箇所:** `Tide/S3/ManifestSharding.swift:7`

シャーディング用途のみで「整合性保証ではない」とコメントが欲しい（既に置いている `Insecure.` プレフィックスで意図は伝わるが、レビューワー向けに一行）。コード自体は安全。

---

## L6. 書込中ファイルの torn upload と in-flight collapse

**Status:** ✅ Fixed（2026-06-09・PR #14 で 3 コミット）・**実機検証済み（2026-06-10）**。症状: 書き込み途中のファイル（`mkfile` で成長中の 1.2GB）を watcher が拾い、Uploader が 850MiB 時点の千切れた内容をアップロード。書き込み完了後の再 enqueue が**処理中の行**との `UNIQUE(path)` collapse で飲み込まれ（処理完了時の行削除で消失）、ローカル ≠ DB ≠ リモートの**無エラー乖離**が次回フルスキャンまで残存した（バックアップツールとして最悪クラス）。

**真因は 2 つの独立欠陥**（当初疑った `DebounceQueue.fire` の並行は無関係＝enqueue 側 `handleDebounced` は `@MainActor` + GRDB 単一ライタで直列化されており、同 path の enqueue が並行することはない）:

1. **in-flight collapse**: enqueue は `INSERT OR REPLACE`（`UNIQUE(path)`）で、処理中に届いた新イベントを**新しい AUTOINCREMENT id の行**へ置換する（＝完全版を上げ直せという正当な指示）。一方、完了/失敗処理がキュー行を **`path` 基準**で削除・更新していたため、旧 in-flight 行の完了がこの新行まで巻き込み消去していた。→ **修正: キュー行のライフサイクルを `item.id` 基準に統一**（`Uploader.processUpload/processDelete`、`SyncEngine.handleProcessingFailure` の retry/give-up/size-limit、`convertQueueItemToDelete`）。新行は旧行の完了/失敗に巻き込まれず次周回で再処理されて自己修復する。

2. **torn read**: そもそも成長中ファイルを読んで torn な内容をコミットしていた。→ **修正: 安定化ゲート（A-detect）**。単一 `O_NOFOLLOW` FD で読み終えた後に同 FD を再 `fstat` し、開始時の (size, mtime) と変化（size 変化 or mtime 前進）があれば不安定とみなす（純粋関数 `StabilityCheck.isStable`）。シングルパートは `putObject` 前に判定して**不安定なら PUT しない**（現行 S3 版を torn で上書きしない）、マルチパートは `completeMultipartUpload` 前に判定して**不安定なら abort + (resume 時) checkpoint クリア**（complete しないので現行版は無傷、新 mtime でフル再開）。いずれも `SyncError.fileChangedDuringUpload` を投げる。さらに**マルチパートは read ループ内で逐次 early-bail**（読了量が開始時 size 超過＝成長／`reader.info()` の mtime 前進＝in-place 書換）し、次パートを PUT する前に throw する＝成長/変化し続ける大ファイルで「満額 PUT → 不安定検知 → 全 abort」を毎リトライ繰り返す PUT 課金・帯域の浪費を避ける（PR #14 レビュー Medium）。

書込が落ち着くまで安定しないファイル（ログ/DB 等）は、`handleProcessingFailure` が `fileChangedDuringUpload` を **give-up カウント（attempts）に載せず**安定するまで延期（`LocalDatabase.deferUnstableQueueItem`、再検査間隔は保留経過に比例・上限 300s）。一定時間安定しなければ「まだバックアップされていない」を `recentIssues` / `sync_log` に **1 回だけ**可視化（dedup）。＝torn を出さず、取りこぼしも黙らせない。

**該当箇所:** `Tide/S3/Uploader.swift`（id 基準削除・シングルパート安定化ゲート）／`Tide/S3/MultipartUploader.swift`（`expectedStat`・complete 前判定）／`Tide/Core/StabilityCheck.swift`（判定）／`Tide/Core/SyncEngine.swift`（id 基準失敗処理・`handleUnstableFile`・`pruneUnstableWarned`）／`Tide/Storage/LocalDatabase.swift`（`deferUnstableQueueItem`）。回帰: `LocalDatabaseTests`（id 基準削除・defer）／`StabilityCheckTests`／`MultipartUploaderTests`（安定→complete・不安定→abort）。

**実機検証（2026-06-10・バケット `dev-tide`・同期ルート `/Users/hige/Tide`）:** 成長し続ける大ファイルを 2 パターンで投入して統合挙動を確認した。① バースト＋休止（~440MiB）＝デバウンス再発火でキュー行 id が次々置換（89→91→92→94）。成長中に `Uploaded` ログは一切出ず（torn 未コミット）、安定化後に完全版が載った。古い in-flight 行の完了が新 id 行を巻き込み消去しない証拠として **完全版の二重アップロード（自己修復）** を観測。② 連続書込（~324MiB）＝単一行が置換されず滞留し、`attempts` は 0 のまま延期（`File changed during upload; deferring`）、**経過 ~30s で「未バックアップ」警告が 1 回だけ**発火（dedup）。両パターンとも安定後に完全版が上がり、**ローカル == DB == S3 の SHA-256 が一致**、残置マルチパートなし（abort 済み）、削除は S3 delete marker 経由で伝播。＝torn を出さず取りこぼしもしないことを実機で確認。

**据え置き**: `reconcile/削除の配線部が未結合テスト`（docs/09-DEFERRED.md）と同様、`processUpload`/`MultipartUploader` の「不安定 → abort/PUT 見送り」I/O 配線は結合テスト未整備（純粋判定と DB 操作は固定済み・S3 シームの注入面が processUpload 側に無い）。`StabilityCheck` の差し替え可能化と合わせて将来タスク。

---

## L7. メモリ上の `secretAccessKey` の生存期間

**Status:** ✅ Fixed (2026-05-24) — `SetupWizardWindow.runStartSyncing` 成功直後に `accessKeyId` / `secretAccessKey` を `""` で参照切断。Swift `String` のヒープ実体は GC 任せだが、ライブなオブジェクトグラフからは外れる。

**該当箇所:** `Tide/UI/SetupWizardWindow.swift:11`

SwiftUI の `@State private var secretAccessKey: String = ""` は SetupWizardWindow がディスポーズされるまで残り、`String` は zeroize できない。仕様上不可避だが、`runStartSyncing` 完了直後に `secretAccessKey = ""` を代入して参照を切る程度は意味がある（残留はあくまでヒープ任せだが、ライブなオブジェクトグラフからは切れる）。

---

## L8. `.syncignore`（リモート由来の除外パターン）の取り扱い

**Status:** ✅ Fixed (2026-06-04) — M3 で `.syncignore` 対応を追加。機密網の否定不可・symlink 非追従・サイズ/件数上限は実装済み。
当初の「ReDoS 回避」は誤りで、生成された正規表現自体がバックトラッキングで爆発し得た（下記 F1）。**F1 は線形時間グロブ照合への置換で構造的に解消（2026-06-04）**。`NSRegularExpression` を廃し、トークン列 + reachable-set DP（`O(パターン長 × パス長)`）に置き換えた。残る上限（サイズ 256KB / 件数 10,000 等）は資源消費の有界化として維持。

**該当箇所:** `Tide/Core/SyncIgnoreMatcher.swift` / `Tide/Core/IgnoreDecision.swift` / `Tide/Core/SyncEngine.swift`

- **機密網は否定 `!` で覆せない**: `IgnoreDecision.shouldSkip` はハードコード除外（`HardcodedIgnoreRules`）を最優先で評価し、`.syncignore` のユーザパターン（否定含む）より常に優先する。悪意ある / 壊れたリモート `.syncignore` に `!.env` 等を書かれても、`.env` などの機密ファイルが同期対象に戻ることはない。
- **DoS（サイズ/件数）回避**: ユーザ正規表現は受け取らず、ファイルサイズ上限 256 KB / パターン数上限 10,000 で巨大・大量パターンによる資源枯渇を防ぐ。
- **✅ ReDoS は構造的に解消（F1, 2026-06-04）**: `NSRegularExpression`（ICU = バックトラッキング）での照合を廃し、グロブをトークン列へコンパイルして reachable-set DP で評価する線形時間照合（`O(パターン長 × パス長)`）に置換した。`*a*a*…` 系でも破滅的バックトラッキングが起こらない。詳細は下記 F1。
- **読込経路の安全性**: `.syncignore` の読込は `PathValidator.resolveSafely(relativePath: ".syncignore", syncRoot:)` 経由で、シンボリックリンクは追従しない。
- **影響の上限**: リモート由来パターンができるのは「除外」か（否定での）「再包含」のみ。再包含してもハードコード除外は覆せないため、最悪でも「同期されるべきファイルが同期されない（可用性）」に留まり、機密漏洩には繋がらない。

### F1. `.syncignore` グロブ→正規表現の破滅的バックトラッキング（ReDoS）

**Status:** ✅ Fixed (2026-06-04) — 恒久解に到達。`SyncIgnoreMatcher` から `NSRegularExpression` を廃し、グロブをトークン列（`literal` / `anyOne`(`?`) / `starNonSlash`(`*`) / `slashStarSlash`(`**/`) / `dotStar`(末尾 `**`)）へコンパイルし、照合を **reachable-set DP** で行う線形時間アルゴリズム（`O(パターン長 × パス長)`、各トークンが到達集合を O(n) で更新、バックトラッキング無し）に置換した。これにより `*a*a*…` 系の多ワイルドカードでも破滅的バックトラッキングが**構造的に起こり得ない**。前段の速攻ガード（パターン長 256 / ワイルドカード数 8 / 照合入力長 1024）は ReDoS 防御の load-bearing ではなくなったが、防御的サニティ上限として保持（資源消費の有界化）。`SyncIgnoreMatcherTests` は既存の意味論テスト全件を回帰オラクルに維持し、`testLinearMatcherMatchesReferenceRegex`（旧 regex 実装との 3,000 ケース differential fuzz）で意味論一致を、`testPathologicalPatternMatchesInLinearTime`（8 ワイルドカード × 1024 文字非一致入力が即時返る）で線形性を担保。

**該当箇所:** `Tide/Core/SyncIgnoreMatcher.swift`（旧 `globToRegex`、現 `tokenize` / `matches` / `isIgnored`）。評価経路は
`IgnoreDecision.shouldSkip` → `SyncEngine.reconcileRemoteEntry` / `performFullScan` / `processEventToQueue`。

**重要度:** Low〜Medium（可用性のみ・復旧可能。前提は C1/C2 と同じ「攻撃者が S3 バケットを書ける」）。

**内容:** `globToRegex` は `*` / `**` / `?` を `[^/]*` / `.*` / `(?:.*/)?` / `[^/]` に展開し、
`NSRegularExpression`（ICU = バックトラッキング NFA）で照合する。`[^/]*` が連続する正規表現
（例: グロブ `*a*a*a*…*z`）は、末尾が一致しない入力に対して超多項式的にバックトラッキングする。
`maxPatterns=10,000` / `maxBytes=256KB` の上限は無力（約 40 文字の単一パターンで成立）。

**実証:** `globToRegex` と等価な正規表現（`[^/]*a` を 15 連結 + 末尾不一致文字）を 40 文字入力に照合 →
**12 秒経過しても完了せず**（線形マッチャなら μ 秒）。

**「既存追跡は触らない（gitignore 純正）」は止血にならない（重要）:** `IgnoreDecision.shouldSkip` は
重い `matcher.isIgnored(path)` を tracked / 未追跡を問わず**先に**評価し、`isAlreadyTracked` は
マッチ完了「後」の出し分けに過ぎない。よって既存同期済みファイルのパスでもフルスキャンのたびに照合が走る。
さらに攻撃者は `reconcileRemoteEntry` で**マニフェスト由来の新規（未追跡）パス**を注入して確実に発火させられる。

**影響:** `Task.detached` ワーカが 100% CPU で無限スピンし、remote pull / full scan が完了しなくなる。
データ消失・ルート脱出は無い。`.syncignore` から該当行を消せば復旧可能。

**対応（2026-06-04 完了）:**
- ✅ (恒久) `NSRegularExpression` を廃し、線形時間のグロブ照合（トークン列 + reachable-set DP）へ置換。入力長に比例する計算量を構造的に保証し、`**` / 否定 / アンカー / dirOnly 等の既存セマンティクスを正確に移植した（旧 regex 実装との differential fuzz で同値を確認）。
- ✅ (防御) パターン単位の `*` / `?` 個数（8）と 1 行長（256）、照合対象パス長（1024）の上限は維持（ReDoS 防御としては不要になったが、資源消費の有界化として保持）。
- ✅ `TideTests/SyncIgnoreMatcherTests.swift` に「病的パターン × 非一致入力が即座に返る」回帰（`testPathologicalPatternMatchesInLinearTime`）と、旧実装との differential fuzz（`testLinearMatcherMatchesReferenceRegex`）を追加。

---

## L9. Uploader が symlink 追従 API で読む（読込時の symlink 再チェック無し）

**Status:** ✅ Fixed (2026-06-02) — M3 で `processUpload` を `NoFollowFileReader`（`open(path, O_RDONLY | O_NOFOLLOW)`）に置換。最終コンポーネントが symlink なら `open` が ELOOP を返し `FileOpenError.isSymbolicLink` として拒否（`upload_queue` から当該行を除去＝無限リトライ防止 ＋ `sync_log` error 記録 ＋ 警告ログ `privacy: .private`、`convertQueueItemToDelete` は使わない＝リモートの正データを誤って消さない）。**チェック〜読込間の再差し替え窓は消滅**: 検知に使う FD と、ハッシュ計算・本体読込/パート送信に使う FD が同一になったため（M5 と一括解消）。`NoFollowFileReaderTests` に symlink 拒否（ELOOP）の回帰テストを追加。**残存範囲**: `O_NOFOLLOW` は最終コンポーネントのみ。祖先 symlink は `resolveSafely` の字句検証とスキャンの skip に委ねる。

**該当箇所:** `Tide/S3/Uploader.swift` `processUpload` / `Tide/Core/NoFollowFileReader.swift`。

**重要度:** Low（防御多重化）。同一ユーザ権限ゆえ権限昇格は無い。

**内容:** symlink は走査時（`SyncEngine.performFullScan`）と FSEvents 時（`FileWatcher` が
`kFSEventStreamEventFlagItemIsSymlink` をスキップ）に弾くが、**アップロード直前に再チェックしない**。
通常ファイルとしてキュー投入された後に symlink へ差し替える TOCTOU 窓があると、`Data(contentsOf:)` が
symlink を辿り、リンク先（例: `~/.ssh/id_rsa`）の中身を S3 へ送り得る。symlink 保護を回避する
クラウド持ち出し経路。

**推奨修正（実装スレッド向け）:**
- `processUpload` の `resolveSafely` 後に `resourceValues(forKeys: [.isSymbolicLinkKey])` を確認して拒否。
- 理想は `O_NOFOLLOW` で open し、同一 FD からハッシュ計算と本体読込を行う（M5 の TOCTOU も同時解消）。

---

## L10. マルチパートアップロード中の「その場切り詰め」で `CompleteMultipartUpload` が失敗

**Status:** ✅ Fixed (2026-06-02) — 空 parts ガードを 2 箇所に追加。`TideS3Client.completeMultipartUpload` 入口で `parts.isEmpty` を弾き、`MultipartUploader.upload` でも task group 後に `parts.isEmpty`（＝総バイト 0、切り詰め）を検知して明示エラーを投げる（catch が `abortMultipartUpload` → 上位のファイル単位リトライ → 次回スキャンが縮小後サイズでシングルパート再送して自己回復）。`MalformedXML` をリトライ空振りする前に確定失敗させる。`xhigh` コードレビュー（2026-06-02）で検出・検証（CONFIRMED）。

**該当箇所:** `Tide/S3/MultipartUploader.swift` `upload`（読込ループ）、`Tide/S3/S3Client.swift` `completeMultipartUpload`。

**重要度:** Low（**可用性**。攻撃者ではなく「アップロード対象ファイル自身の局所的な変更」が必要＝ローカル書込権限が前提で、実害は自己 DoS 的。**整合性は SHA で担保**され、破損したままアップロードが完了することは無い）。

**内容:** fstat で 16 MiB 超 → マルチパート選択。`createMultipartUpload` のネットワーク往復の間に対象ファイルが「その場切り詰め」（`: > file`、ログの copytruncate など。**inode を保持したまま縮める**操作）されると、`O_NOFOLLOW` の FD は縮んだ長さを読む。結果 `readChunk` が即 `nil` → `parts` が空 → `completeMultipartUpload(parts: [])` で S3 が `MalformedXML`、または非最終パートが 5 MiB 未満 → `EntityTooSmall`。旧 `Data(contentsOf:)` 一括読みでは起き得なかった挙動（ストリーミング化のトレードオフ）。失敗は汎用エラー扱いで `SyncEngine.handleProcessingFailure` が最大 5 回リトライ後に give up、ファイルは 0/縮小後のサイズで次回スキャンが再エンキューしシングルパートで成功（自己回復）。`completeMultipartUpload` 側にも空 `parts` ガードは無い。

**関連（別 Low・要併記）:** ✅ 解消（2026-06-02・PR #1 レビュー反映）。`handleProcessingFailure` の `fileTooLarge` 分岐は、キュー行削除の DB 書込が失敗すると早期 `return` してバックオフを飛ばし busy-loop しうる問題があったが、**削除失敗時は return せず通常のバックオフ経路へフォールスルー**するよう修正（`attempts++` と `nextRetryAt` が設定される）。発生条件自体（DB 書込失敗＝ディスク満杯/ロック）は稀。

**推奨修正（実装スレッド向け）:**
- `MultipartUploader.upload` で読み終えた総バイト数が 0、または fstat の `size` と大きく食い違う場合に early-return し、delete 変換 or 再 stat（シングル/マルチ再判定）に回す。
- `TideS3Client.completeMultipartUpload` 入口に `parts.isEmpty` ガードを足し、空なら abort して明示エラーにする。
- `MultipartUploader.uploadPartWithRetry` は現状あらゆるエラーを 3 回リトライする（非リトライ可能な `EntityTooSmall` / 認証エラーも含む）。恒久失敗を即時諦める分類を入れると、本件のリトライ空振りコスト（S3 API 課金含む）が減る。

---

## L11. 巨大ファイルのマルチパート・パートサイズが大きく常駐メモリが膨らむ

**Status:** ✅ Fixed (2026-06-02) — `PartPlan` に `maxPartSize = 64 MiB` の cap を導入。目標パート数（9,000）基準値を `[5MiB, 64MiB]` にクランプし、10,000 パートに収まらない超巨大ファイル（おおむね 640GiB 超）だけ「収めるのに必要な最小 partSize」を直接 floor 計算で引き上げる（cap を超えるのはこのときだけ）。これにより現実的な大ファイル（≤640GiB）の常駐メモリは `64MiB × (inflight+1)` ≈ **256 MiB** で頭打ち（従来は 5 TiB で ~2.3 GiB）。あわせて指摘どおり**デッドコードだった防御 `while` ループを撤去**し、直接 floor 計算（`minToFit`）に置換（`partCount ≤ 10,000` は MiB 切り上げにより常に成立）。`PartPlanTests` に cap の回帰を追加。`xhigh` コードレビュー（2026-06-02）で検出。

**該当箇所:** `Tide/S3/PartPlan.swift` `plan`（`targetMaxParts = 9_000`）、`Tide/S3/MultipartUploader.swift`（in-flight バッファ）。

**重要度:** Low（**可用性・資源**。攻撃者起因ではなく、ユーザ自身が巨大ファイルを同期対象に置いたときのメモリ圧。メニューバー常駐アプリで激しいページング／jetsam のリスク）。

**内容:** S3 のパート数上限 10,000 に対して 9,000 で余裕を取った設計が裏目に出て、part 数を抑える代わりに 1 パートを肥大化させている。`O_NOFOLLOW` 単一 FD から順次読みつつ最大 3 パートを in-flight にするため、肥大パート × 4 ぶんの `Data` が常駐する。整合性・正当性に問題は無く、純粋に資源効率の問題。

**推奨修正（実装スレッド向け）:**
- `partSize` に上限（例: 64〜128 MiB）を設け、巨大ファイルは part 数を 10,000 上限まで増やす方向にする。常駐メモリが概ね 5〜10 倍下がる。
- 付随して `PartPlan.plan` 末尾の防御 `while partCount > maxPartCount { partSize += 1MiB }` は**現設計ではデッドコード**（partCount は最大 8,993 で上限に達しない）。partSize 上限を入れるとこのループが実際に機能し始めるので、同時に整理する。

---

## L12. 中断・再開（transfer_state / Range / 決定的 tmp）の攻撃面

**Status:** ✅ Reviewed — Hardening 込みで対応済み (2026-06-05・M3 サブ D)。新規の攻撃面を洗い、下記の緩和を入れた。残る露出は Low（ローカル攻撃者が Caches 配下に書ける前提）。

**該当箇所:** `Tide/Storage/Migrations.swift`（`transfer_state`）、`Tide/Storage/TransferStateStore.swift`、`Tide/S3/Downloader.swift`（`streamObject` / 決定的 tmp / 再開）、`Tide/S3/MultipartUploader.swift`（`ResumeContext`）、`Tide/Core/SyncEngine.swift`（`pruneOrphanTransfers`）。

**重要度:** Low（機密漏えいではなく、ローカル前提の整合性・可用性ハードニング）。

**レビュー観点と結論:**
- **Range ヘッダのインジェクション**: `Range: bytes=<N>-` の `N` は**自前で算出した `Int64`**（再開元の tmp 実サイズ）のみ。リモート由来文字列を入れないので注入余地なし。
- **DB の `tmp_path` を盲信しない**: 再開時は `tmpDir + sha256(relativePath)` から **tmpURL を再計算**し、`persisted.tmpPath == tmpURL.path` のときだけ再開する。DB が改ざんされても tmpDir 外へ書く経路にならない（`relativePath` は事前に `resolveForWrite` で検証済み）。
- **決定的 tmp 名の予測可能性 / 事前設置**: tmp 名は `sha256(relativePath)` で予測可能だが、書込はすべて **symlink 非追従**で行う（PR #4 レビューで fresh 側の追従窓を解消・2026-06-05）。(1) 新規取得は `Downloader.openTmpForWriting(append:false)` が `open(O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW)` で作る（既存 or symlink なら失敗＝追従しない。旧 `createFile` の `removeItem`→作成の TOCTOU を解消）、(2) 再開は `O_WRONLY|O_NOFOLLOW`（加えて開く前に `PathValidator.isSymbolicLink` でも弾く）、(3) 最終的に**マニフェスト SHA と突合**してから `resolveForWrite` 済みパスへ `moveItem`。よって攻撃者が tmp を事前設置しても、内容注入は SHA ゲートで弾かれ、symlink 経由の任意箇所書込は open の `O_NOFOLLOW` で構造的に塞がれる（アップロード側 `NoFollowFileReader` と対称）。
- **サイズ上限（M7 DoS）**: 再開分（既存プレフィクス長）を含む累積長を `entry.size` と突合し超過は破棄（[medium.md](medium.md) M7 参照）。
- **宙ぶらりんリソースの蓄積**: `SyncEngine.start()` 冒頭の `pruneOrphanTransfers()` が、ローカルファイルの消えた upload 行（宙ぶらりん MPU を best-effort `abortMultipartUpload`）、tmp の消えた download 行（当該シャードのキャッシュを sentinel 化**してから**削除＝取り残し防止・2026-06-07 修正）、7 日より古い行を掃除する。S3 側の `tide-abort-incomplete-multipart`（7 日）と歩調を合わせる。
- **secret 非保持**: `transfer_state` は path / UploadId / etag / partSize / mtime / size のみ。認証情報・本文は持たない。

**残ロジック上の据え置き:** ✅ 解消済み（2026-06-07）。prune 本体を `SyncEngine.pruneOrphanTransfers(db:store:syncRoot:now:abortUpload:)`（`nonisolated static`・依存注入＝実 `TideS3Client` 不要）へ切り出し、`TransferPruneTests`（実 DB + abort フェイク）で clear（tmp 消失/stale）・resumable・upload 全分岐の配線を回帰固定。あわせて clear 分岐の `invalidateShardCache` 漏れ（中断 DL の永久取り残し）も修正（`docs/09-DEFERRED.md` 参照）。store 操作自体は従来どおり `TransferStateStoreTests` でカバー。

---

## L13. 診断エクスポートの同梱範囲（プライバシー境界）

**Status:** ✅ Reviewed — サポート用の診断エクスポート機能を追加。**認証情報は含まないが、ファイル名/パス・バケット名・deviceId は含む**境界を確認し、UI と出力に明示した (2026-06-19・PR #24)。

**該当箇所:** `Tide/Core/DiagnosticsExporter.swift`、`Tide/Storage/LocalDatabase.swift`（`snapshot(to:)`）、`Tide/UI/SettingsWindow.swift`（「Export Diagnostics…」）。

**重要度:** Low（攻撃者前提なし。本人画面の操作で本人のデータを本人が選んだ場所に書き出すだけ。露出はメタデータ＝ファイル名/パス・バケット名・リージョン・deviceId で、**認証情報は含まない**）。

**境界と対策:**
- **含まない**: AWS 認証情報。`DiagnosticsExporter` は Keychain を一切参照せず、入力は `ConfigStore` の非機密フィールドと `sync_log` / DB のみ（構造的に漏れない）。
- **含む**: DB スナップショット（`VACUUM INTO`）と `sync-log.txt` に、同期フォルダ配下の**ファイル名/相対パス**・バケット名・リージョン・deviceId。診断目的で必要。
- **明示**: CLAUDE.md が path を常に `privacy: .private` で扱う方針に合わせ、**テスターが驚かないよう**「含む/含まない」を Settings の文言と `diagnostics.txt` の Note に明記（生成物を第三者に送る前提のため）。
- **出力先**: `NSSavePanel` でユーザが選んだ場所のみ。重い IO は `writeArchive`（nonisolated）でメインアクター外で実行。`DiagnosticsExporterTests` が純粋テキスト（シークレット非混入）と zip 生成（同梱 3 ファイル）を回帰固定。

## L14. 設定 export / import の同梱範囲（プライバシー境界）

**Status:** ✅ Reviewed — 非機密設定の JSON export/import 機能を追加。**認証情報・`deviceId` を構造的に含めない**境界を確認した (2026-07-01・Issue #29)。

**該当箇所:** `Tide/Core/SettingsTransfer.swift`、`Tide/UI/SettingsWindow.swift`（「Export/Import Settings…」）、`Tide/UI/SetupWizardWindow.swift`（「Import settings…」）。

**重要度:** Low（攻撃者前提なし。本人画面の操作で本人の設定を本人が選んだ場所に書き出す/読み込むだけ。露出はバケット名/リージョン/syncRoot パスと tunables のみで、**認証情報・deviceId は含まない**）。

**境界と対策:**
- **含まない**: AWS 認証情報（Keychain）と `deviceId`（端末固有 ID）と `setupCompleted`。`SettingsTransfer.Payload` にフィールドが無く構造的に漏れない。新 Mac へは AWS キーをウィザードで再入力＝「認証情報は Data Protection Keychain のみ」を維持。`SettingsTransferTests` が JSON に `deviceId` / `accesskey` / `secret` が出ないことを回帰固定。
- **含む**: バケット名・リージョン・syncRoot 絶対パス・tunables（polling / サイズ上限 / 帯域 / 通知）。L13 同様メタデータのみ。
- **入出力先**: export は `NSSavePanel`、import は `NSOpenPanel`（`.json`）でユーザが選んだ場所のみ。import のスキーマ版検証は **現版以下のみ受理**（`unsupportedVersion` / `malformed` を `LocalizedError` で UI へ）。

## L15. 削除済み一覧キャッシュの at-rest 内容（プライバシー境界）

**Status:** ✅ Reviewed — 「Deleted files」タブの軽量キャッシュを追加。**認証情報を含まず、保存するのは削除済みファイルの相対パス + 版メタデータ + bucket 名のみ**で、露出はローカル DB が既に持つパスメタデータと同等であることを確認した (2026-07-01・Issue #29 (b))。

**該当箇所:** `Tide/Core/DeletedFilesCache.swift`（`~/Library/Caches/Tide/deleted-files-cache.json`）、`Tide/UI/VersionHistoryModel.swift`。

**重要度:** Low（攻撃者前提なし。本人のホーム配下 Caches に派生データを置くだけ。新規の機密露出は無し）。

**境界と対策:**
- **含まない**: AWS 認証情報。`DeletedFilesCache.Payload` は `schemaVersion` / `bucket` / `updatedAt` / `[FileVersionHistory]`（相対パス + 版メタデータ）のみ。
- **at-rest 場所**: `~/Library/Caches/Tide/`（本人ホーム配下）。派生データ＝S3 `listObjectVersions` からいつでも再生成可能。`factoryReset` が `Caches/Tide` ごと削除＝キャッシュも消える。
- **bucket キー**: `load(bucket:)` は現 bucket 一致時のみ採用（別バケットの一覧を出さない）。スキーマ不一致・壊れは nil（無効）扱い。

## L16. File Provider 世代ログの at-rest 内容（プライバシー境界）

**Status:** ✅ Reviewed — M5 Phase 4 の増分列挙用に、マニフェストスナップショットの世代ログ（直近 8 世代）を App Group コンテナ内 Caches に追加。**認証情報を含まず、保存するのは相対パス + ファイルメタデータ（size/mtime/sha256/versionId/etag）+ bucket 名のみ**で、露出はローカル DB / S3 マニフェストが既に持つメタデータと同等であることを確認した (2026-07-04・M5 Phase 4)。

**該当箇所:** `TideCore/S3/ManifestGenerationLog.swift`（`<App Group>/Library/Caches/Tide/fileprovider-manifest-log.json`）、`TideCore/S3/ManifestGenerationCache.swift`（書き手は File Provider 拡張プロセスのみ）。

**重要度:** Low（攻撃者前提なし。本人の App Group コンテナ配下に派生データを置くだけ。新規の機密露出は無し）。

**境界と対策:**
- **含まない**: AWS 認証情報。`ManifestGenerationLog.Payload` は `schemaVersion` / `bucket` / `[Generation]`（anchor / fetchedAt / shardEtags / files = マニフェスト由来メタデータ）のみ。`deviceId` フィールドはマニフェスト側の書込元表示値（`ManifestFileEntry.deviceId`）の写しで、Keychain 秘匿対象の端末 ID とは別物。
- **at-rest 場所**: App Group コンテナ内 `Library/Caches/Tide/`。派生データ＝S3 マニフェストからいつでも再生成可能。消えても anchor 未知 → `.syncAnchorExpired` → 全再列挙で自己回復。`factoryReset` が group Caches を削除・`make reset` は GROUP_CONTAINER ごと削除。
- **bucket キー**: `load(bucket:)` は現 bucket 一致時のみ採用（別バケットの世代で diff しない）。スキーマ不一致・壊れは nil（cold 扱い）。
- **取り込みゲート**: 世代へ入るデータは `ManifestSnapshotLoader` が `validateShardId` / `validateRelativePath` を通した後のもののみ（`ManifestReader.read` と同一のセキュリティゲート）。
