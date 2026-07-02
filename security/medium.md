# 🟡 Medium

## M1. `Package.resolved` が `.gitignore` 対象

**Status:** ✅ Fixed (2026-05-24) — `.gitignore` から `Package.resolved` を除去し、コミット時の意図がわかるよう注記コメントを追加。

**該当箇所:** `.gitignore:22`

アプリケーション（ライブラリではない）では Package.resolved を**コミットすべき**。さもないと再ビルドのたびに依存パッケージのマイナー/パッチが浮動し、サプライチェーン上の再現性とインシデント追跡が壊れる。SBOM 出力やセキュリティスキャンの基盤としても必須。

---

## M2. `factoryReset` が DB ファイルを残す

**Status:** ✅ Fixed (2026-05-24) — `factoryReset` で `~/Library/Application Support/Tide` と `~/Library/Caches/Tide` をディレクトリごと削除し、`ConfigStore.resetIncludingDeviceId()` で deviceId も含めて UserDefaults をクリアするように変更。`make reset` と同じ挙動になる。（2026-07-02 追記・M5 Phase 2）DB/設定の正位置が App Group コンテナへ移ったのに伴い、`factoryReset` は group container 配下の DB・group suite の defaults・standard defaults（sandbox 下ではコンテナ側 plist）も併せて消す。`make reset` も group container / app container を消すよう更新済み。（2026-07-03 追記・PR #49 レビュー #5）**sandbox 化により `factoryReset` は実ホームの旧ロケーション残置分（移行元 `~/Library/Application Support/Tide/db.sqlite`・旧 `~/Library/Caches/Tide`）には届かなくなった**（`.applicationSupportDirectory` 等がコンテナ内に解決され、実パスへのアクセスも sandbox が拒否）。旧残置分（全ファイルパス+ハッシュを含む DB、`.part` 断片）の完全削除は sandbox 外の `make reset` でのみ可能。M2 の「完全消去」は「アプリから届く範囲＝現行の正位置」に対して成立し、pre-sandbox 残置分だけが例外として残る（一度きり・以後増えない）。

**該当箇所:** `Tide/App/AppEnvironment.swift:114-121`

```swift
func factoryReset() async {
    await engine?.stop()
    engine = nil
    s3 = nil
    database = nil
    config.reset()
    try? keychain.delete()
}
```

`database = nil` は Swift 参照を捨てるだけで、`Application Support/Tide/db.sqlite` は**残る**（`sync_log` に過去パス・SHA・エラー文字列が残存）。同様にキャッシュの `~/Library/Caches/Tide/tmp` も残る。ConfigStore.reset 自身も `deviceId` を残す（意図的かもしれないが、リセット後に再セットアップしたユーザが旧デバイス ID で `(cached)` などのマニフェスト痕跡と混ざるのが少々気持ち悪い）。

**対策:** `LocalDatabase.defaultURL()` のファイルを `try? FileManager.default.removeItem(at:)`、tmpDir も削除、`deviceId` も含めた完全リセット。Makefile の `make reset` と挙動を揃える。

---

## M3. シャード ID の検証なし

**Status:** ✅ Fixed (2026-05-24) — `PathValidator.validateShardId` で `^[0-9a-f]{2}$` を強制。`ManifestReader.read()` の index 読み込み段で不正な shardId エントリを drop。`S3Client.getShard` / `putShard` / `deleteShard` の入口でも検証して、S3 キー組み立て時の `..` 混入を防ぐ。

**該当箇所:** `Tide/S3/ManifestReader.swift:35-37`、`Tide/S3/S3Client.swift:270-291`

```swift
remoteShardEtags = index.value.shards.mapValues { $0.etag }
for (shardId, etag) in remoteShardEtags { ... }
```

`index.json` の `shards` キーは攻撃者制御可能（C1 と同じ前提）。`shardId` に `..` や `/` が含まれていても `.tide/shards/\(id).json` という S3 キーが組み立てられる。S3 自体は受け入れるし、その shard の中身は ManifestShard としてデコードされローカル DB に書き込まれる。

**対策:** `shardId` を `^[0-9a-f]{2}$` で弾く（`ManifestSharding.shardId` の出力と同型式）。

---

## M4. `getObject` のレスポンス本文サイズ無制限

**Status:** ✅ Fixed (2026-05-24) — `S3Client.getObject(key:maxBytes:)` を追加。サーバ申告の `contentLength` で事前に弾き、受信完了後にも `data.count` を再チェックする二段構え。**現状 `getObject` の呼び出しはマニフェスト経路（`getIndex`/`getShard`）の 16 MiB のみ**で、ファイル本体のダウンロードは M3 サブ D-D3 で `streamObject` へ移行済み（サイズ上限は `Downloader` 側の sink で `entry.size` と突合＝M7 参照）。よって `getObject` の 200 MiB 既定値は実質未使用（防御的に残置）。

**該当箇所:** `Tide/S3/S3Client.swift:219-242`

```swift
data = try await body.readData() ?? Data()
```

`getObject` は manifest 取得にも使われるが、攻撃者が `.tide/index.json` を 10 GB に膨らませれば、Tide はメモリ上に丸ごと吸い込みクラッシュする。M1 のローカル DoS 程度だが、ダウンロード経路（最大 5 並列 × ファイル）の memory pressure を上限化する意味で `maxBytes` を入れた方がよい（マニフェストは MiB オーダ上限で十分）。

---

## M5. アップロードのハッシュ計算とデータ読込が別 syscall（TOCTOU）

**Status:** ✅ Fixed (2026-06-02) — M3 マルチパート対応で `Uploader.processUpload` をストリーミング化。`NoFollowFileReader`（`open(path, O_RDONLY | O_NOFOLLOW)`）で **1 回だけ open** し、ハッシュ計算と本体読込/パート送信をすべて同一 FD から行う。これにより「ハッシュ用 `HashCalculator.sha256(of:)` の open → 本体用 `Data(contentsOf:)` の open」の 2 回 open に存在した TOCTOU 窓を解消。最終コンポーネントが symlink なら `open` が ELOOP を返し `FileOpenError.isSymbolicLink` として拒否（L9 と同根で一括解消）。**残存範囲**: `O_NOFOLLOW` は最終コンポーネントのみ有効で、祖先ディレクトリの symlink は対象外。これは `PathValidator.resolveSafely`（字句検証）とフルスキャン / FSEvents の symlink skip に委ねる（過大評価しない）。

**該当箇所:** `Tide/S3/Uploader.swift`（processUpload）/ `Tide/Core/NoFollowFileReader.swift` / `Tide/S3/MultipartUploader.swift`

`HashCalculator.sha256(of:)` でハッシュを取り、その後別途 `Data(contentsOf: fullURL)` で読み直してアップロードしている。間にファイルが書き換えられると、メタデータの sha256 と実バイトが食い違い、整合性検証（`Downloader.swift:42`）に失敗する。検知できるので安全側に倒れているが、**アップロード後の DB に古いハッシュが残る不整合**が起こりうる。

**対策:** ハッシュ計算をストリーミングで行いつつ同じバッファをアップロードに使う、または putObject 後に取得 ETag と「アップロードしたバイトから計算した sha256」を再検証してから DB 更新。

---

## M6. ダウンロード書込の祖先ディレクトリ symlink による syncRoot 脱出（C1/C2 の補完漏れ）

**Status:** ✅ Fixed (2026-06-01) — `PathValidator.resolveForWrite(relativePath:syncRoot:)` を新設。`resolveSafely` に加え、解決後 URL の**最深の既存祖先ディレクトリ**の実パス（`resolvingSymlinksInPath()`）が syncRoot の実パス配下に収まることを検証する（root 側も `resolvingSymlinksInPath()` で解決し同一基準で比較）。`Downloader.download` / `applyRemoteDeletion` / `renameLocalForConflict` の書込・削除入口をこの API 経由に変更。`ValidationError.escapesSyncRootViaSymlink` を追加。`TideTests/PathValidatorTests.swift` に祖先 symlink 脱出を弾く回帰テスト（`testResolveForWriteRejectsAncestorSymlinkEscape` ほか）を追加。

**該当箇所:** `Tide/Core/PathValidator.swift` `resolveForWrite`、`Tide/S3/Downloader.swift` `download` / `applyRemoteDeletion` / `renameLocalForConflict`。

**重要度:** Medium（任意絶対パスは書けず、既存 symlink の指す先に限定。前提は C1 と同じマニフェスト改ざん）。

**内容:** `resolveSafely` は `standardizedFileURL` で root 配下を判定するが、`standardizedFileURL` は
`.` / `..` を**字句的に**解決するだけで **symlink は解決しない**（`resolvingSymlinksInPath` ではない）。
`Downloader.download` の symlink ガードは**最終コンポーネントのみ**（`isSymlink(at: fullURL)`、しかも
未作成パスでは false）。よって syncRoot 配下の**祖先ディレクトリが外部を指す symlink**（例: 開発者が
`data/` を外部ボリュームへ symlink）だと、マニフェストエントリ `data/x/evil` は字句上 root 配下なので
`resolveSafely` を通過し、`createDirectory(withIntermediateDirectories:)` / `moveItem` が symlink を辿って
**実体側（例: `/Volumes/ext`・`/tmp/...`）へ書き込む** = 実 syncRoot 外への書き込みになる。

C2 はアップロード走査（symlink スキップ）と最終書込先は守るが、**ダウンロード書込経路の祖先 symlink** は
未防御。前提は「syncRoot 内に既存の symlink ディレクトリがある」＋「マニフェスト改ざん（C1 と同じ）」。

**推奨修正（実装スレッド向け）:**
- 解決後に「最深の既存祖先ディレクトリの実パス（`resolvingSymlinksInPath`）が `syncRoot` の実パス配下に収まる」
  ことを検証するヘルパを `PathValidator` に追加。または各パスコンポーネントを走査して symlink を拒否。
- `Downloader.download`（親ディレクトリ作成直前）/ `renameLocalForConflict` / `applyRemoteDeletion` の入口に適用。
- `TideTests/PathValidatorTests.swift` に「祖先 symlink 経由の脱出を弾く」回帰テストを追加。

---

## M7. ストリーミングダウンロードのレスポンスサイズ無制限（M4 の回帰）

**Status:** ✅ Fixed (2026-06-02、2026-06-04 にサブ D-D3 で機構を更新) — 当初は `Downloader.download` が `downloadToFile(key:into:maxBytes: entry.size)` を呼ぶ形で塞いだ。**サブ D-D3（中断・再開）で `downloadToFile` を Range 対応の `TideS3Client.streamObject(key:rangeStart:sink:)` に置換**したため、DoS ガードは **`Downloader` 側の sink へ移動**: ストリーミングの sink で受信累積長（再開時は既存プレフィクス長を含む `total`）を**マニフェストの真実サイズ `entry.size`** と突合し、超過したら `DownloadAbort.tooLarge` で打ち切り、**部分 tmp を破棄し `transfer_state` 行をクリアして throw**（＝サイズ食い違いは「保持して再開」に倒さず仕切り直す）。M4 が `getObject` で塞いだ「巨大本文によるローカルディスク枯渇 DoS」を復元経路でも維持する。復元方向はユーザのアップロード上限（`uploadSizeLimitBytes`）ではなく真実値であるマニフェスト `size` を基準にする。`DownloaderTests` でフェイク seam による回帰確認。`xhigh` コードレビュー（2026-06-02）で検出。

**該当箇所:** `Tide/S3/S3Client.swift` `streamObject`（旧 `downloadToFile`）、`Tide/S3/Downloader.swift` `download`（sink で `total > entry.size` を弾く）。

**重要度:** Medium（前提は C1 / M4 と同じ＝マニフェスト改ざん or バケットを書ける第三者。機密漏えいではなく**可用性＝ローカルディスク枯渇**）。

**内容:** メモリはチャンクで有界（`.stream` 経路で SDK が常時ストリーミングすることは検証済み）だが、**tmpDir への書込はストリーム全長ぶん行われ、SHA 検証は全部書き終えた後**。よって C1 の攻撃者が小さなマニフェストエントリを巨大オブジェクトに向ける（あるいは S3 が巨大本文を返す）と、SHA 不一致で tmp を捨てる前に同期ボリュームのディスクを食い尽くせる。M4 が `getObject` で塞いだ DoS が、復元経路で再び開いている。`downloadToFile` 内部には `maxBytes` 指定時の二段チェック（contentLength 事前弾き + 累積長）の素地が既にあり、呼び出し側が値を渡していないだけ。

**関連（同経路の軽微な挙動変化・別 Low）:** ✅ 併せて解消。復元の親ディレクトリ作成を **SHA 検証後**（move 直前）に移動し、SHA 不一致で捨てるときに空ディレクトリの litter を `syncRoot` に残さないようにした。

**推奨修正（実装スレッド向け）:**
- `Downloader.download` で `downloadToFile(key:into:maxBytes:)` にマニフェストの `entry.size`（+ 小さなスラック）を渡し、サーバ申告 contentLength と受信累積長の両方で弾く。
- もしくは tmpDir のボリューム空き容量に対する上限 / ハード上限を設ける。復元方向はアップロード上限を適用しない方針（docs）なので、真実値であるマニフェスト `size` を基準にするのが筋。
- `TideTests` に「contentLength 過大／本文過大で `downloadToFile` が弾く」回帰を追加。
