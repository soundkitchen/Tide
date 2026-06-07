# 🟢 Low / Hardening

## L1. App Sandbox 無効

**Status:** 🟡 Partial (2026-05-24) — 死蔵キー `tide.syncRootBookmark` を `ConfigStore` から削除（bookmark を保存していないのに key だけ残っていた）。App Sandbox 化自体は docs どおり M3+ で security-scoped bookmark とセットで実装予定。

**該当箇所:** `project.yml:18`

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

## L6. `DebounceQueue.fire` の競合

**Status:** ⚠ 実害を確認（2026-06-07・M3 サブ D 受け入れテスト中）— 要対応。旧想定「`UNIQUE(path)` collapse で実害は出ない」が覆った: 書き込み途中のファイル（`mkfile` で成長中の 1.2GB）を watcher が拾い、Uploader が 850MiB 時点の千切れた内容をアップロード。書き込み完了後の再 enqueue が**処理中の行**との `UNIQUE(path)` collapse で飲み込まれ（処理完了時の行削除で消失）、ローカル ≠ DB ≠ リモートの**無エラー乖離**が次回フルスキャンまで残存した。バックアップツールとしてサイレントな取りこぼしは最悪クラスの症状。対策（handler 側の in-flight 集約・書込安定化待ち・処理開始時の行スナップショット比較等）は設計相談のうえ別タスクで実施。それまでのワークアラウンド: 大ファイルは同期ルート外で作成して `mv` で atomic に入れる。

**該当箇所:** `Tide/Core/DebounceQueue.swift:45-52`

actor 内で `Task.detached` を `for` ループから発火している。`emitter` 側で長時間ブロックすると同時実行が起きるため、SyncEngine 側で同じ key の処理が**並列に走り得る**ことを念頭に置く必要がある（Uploader は同じ path への upload/delete が 5 並列タスクから同時に走るケース）。実害（= DB 整合性破壊）はなさそうだが、UploadQueueRecord に対する `.replace`/`.delete` の order が崩れる可能性は要確認。

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

**残ロジック上の据え置き:** ✅ 解消済み（2026-06-07）。prune 本体を `SyncEngine.pruneOrphanTransfers(db:store:syncRoot:now:abortUpload:)`（`nonisolated static`・依存注入＝実 `TideS3Client` 不要）へ切り出し、`TransferPruneTests`（実 DB + abort フェイク）で clear（tmp 消失/stale）・resumable・upload 全分岐の配線を回帰固定。あわせて clear 分岐の `invalidateShardCache` 漏れ（中断 DL の永久取り残し）も修正（`CLAUDE.md §8` 参照）。store 操作自体は従来どおり `TransferStateStoreTests` でカバー。
