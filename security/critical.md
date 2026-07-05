# 🔴 Critical

## C1. パストラバーサル: リモートマニフェストがローカル任意パスへの書き込みを引き起こす

**Status:** ✅ Fixed (2026-05-24) — `Tide/Core/PathValidator.swift` を新設。`Downloader.download` / `applyRemoteDeletion` / `renameLocalForConflict`、`SyncEngine.reconcileRemoteEntry` / `performFullScan`、`Uploader.processUpload` / `processDelete` の各入口で `validateRelativePath` + `resolveSafely` を呼び、`..` / 絶対パス / NUL / バックスラッシュ / 空コンポーネントを拒否し、解決後 URL が `syncRoot` 配下に収まることも検証する。`ManifestReader.read` が manifest のキーを取り込む前にも検証する。

**該当箇所（対応コード）:** 検証は `Tide/Core/PathValidator.swift`（`validateRelativePath` / `resolveSafely` / `resolveForWrite`）。呼び出し入口は `Downloader.download`（`Downloader.swift:64` の `resolveForWrite`、commit は `:226` の `moveItem`）、`renameLocalForConflict`（`:259-260`）、`applyRemoteDeletion`（`:290`）、`SyncEngine.reconcileRemoteEntry`（`SyncEngine.swift:739`）、`performFullScan`（`:500`）、`ManifestReader.read`。以下は対策前の脆弱だったコード（参考）:

```swift
let fullURL = syncRoot.appendingPathComponent(relativePath)
// ...
try FileManager.default.moveItem(at: tmpURL, to: fullURL)
```

`relativePath` は `ManifestFileEntry`（S3 上の `.tide/shards/XX.json` から取得）に由来し、**ローカル側でサニタイズしていない**。攻撃者が S3 マニフェストを書き換えれば（複数デバイス運用、誤って共有された IAM Key、別ホストのコンプロマイズ etc.）、`relativePath = "../../.ssh/authorized_keys"` のようなエントリで Tide が `syncRoot` 外の任意パスへ書き込む。`appendingPathComponent` は `..` を解決せず素通しする。

**対策（必須）:**
- ダウンロード前に `relativePath` を検証する:
  - 先頭が `/` でないこと
  - 区切られた各コンポーネントが `..` / `.` / 空文字でないこと
  - NUL バイトを含まないこと
  - 解決後の `standardizedFileURL.path` が `syncRoot.standardizedFileURL.path + "/"` で始まること
- 同様の検証を `ManifestReader.read()` の結果適用直後、および `applyRemoteDeletion`、`renameLocalForConflict` の入口にも入れる
- `ManifestSharding.shardId` で `..` を含むキーが入ってきても安全になるよう、`shardId` をデコード時に `[0-9a-f]{2}` 正規表現で弾く

---

## C2. シンボリックリンク経由のサンドボックス回避

**Status:** ✅ Fixed (2026-05-24) — `performFullScan` のウォーカーで `.isSymbolicLinkKey` を取得、symlink は `continue` でスキップ。`Downloader` の書き込み先がシンボリックリンクなら拒否（リンク先実体の書き換えを防ぐ）。`applyRemoteDeletion` も symlink を削除対象から除外。
**修正 (2026-07-05・Issue #54):** 当初対策の「symlink なら `skipDescendants()`」は**削除**した。実測で (1) deep enumeration は symlink ディレクトリへ**そもそも再帰しない**（下の「既定で辿る」という当初の記述は誤りで、この呼び出しは不要）、(2) 現在 item がファイル（symlink）のときに呼ぶと**無関係な隣接ディレクトリ**への再帰がスキップされ、実在する追跡ファイルが削除検出に乗って S3 へ誤 delete される（実害あり・実機発現）ことを確認したため。symlink 非追従の安全性は enumerator の仕様 + `continue` で維持される（回帰テスト: `FullScanSymlinkTests`）。

**該当箇所（対応コード）:** `Tide/Core/SyncEngine.swift` の `performFullScan` / `loadLayeredIgnore`（enumerator 構築 + `.isSymbolicLinkKey` 取得 → symlink は **`continue` のみ**。`skipDescendants()` は「現在 item がディレクトリ」の機密網 dir スキップ＝`loadLayeredIgnore` の `HardcodedIgnoreRules` 分岐でのみ使用 — Issue #54）。Downloader の書き込み先 symlink 拒否（`Downloader.download` 入口）、`applyRemoteDeletion` の symlink 除外。以下は対策前の、symlink を辿っていたコード（参考）:

```swift
let walker = fm.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey, ...],
    options: []
)
```

`FileManager.enumerator(at:)` は**ディレクトリへのシンボリックリンクを既定で辿る**（← **当初 2026-05-24 の想定で、2026-07-05 の実測により誤りと判明**: deep enumeration は symlink へそもそも再帰しない。上の修正注記と Issue #54 参照。仮に辿った場合の懸念として記録を残す）。`syncRoot` 配下に `~/.ssh` を指すシンボリックリンクが置かれれば、その中身が S3 にアップロードされる。FileWatcher 側は `kFSEventStreamEventFlagItemIsSymlink` でスキップしている（`FileWatcher.swift:104`）が、全件スキャン経路では抜ける。

**対策:**
- enumerator の各 URL について `.isSymbolicLinkKey` を取り、シンボリックリンクは無視（`continue` のみ）
- ~~ディレクトリの場合は同様にチェックし、シンボリックリンクなら `walker.skipDescendants()`~~
  （**撤回・Issue #54**: symlink item で `skipDescendants()` を呼ぶと無関係な隣接ディレクトリが
  走査から脱落し、追跡ファイルが S3 へ誤 delete される。enumerator は symlink へ再帰しないため
  `continue` のみが正しい。dir-symlink 非追従の挙動は `FullScanSymlinkTests` でピン留め）
- Downloader 側の `removeItem` / `moveItem` も、`fullURL` が既存のシンボリックリンクならエラーで弾く（リンク先実体の置換を防ぐ）

---

## C3. S3 サーバサイド暗号化が未指定 / バケットの Public Access Block 未設定

**Status:** 🟢 Fixed (HTTPS 強制まで完了 2026-06-23・Issue #26 / B) — `putObject`（および `createMultipartUpload`）に `serverSideEncryption: .aes256` を明示。プロビジョニング時に `enforcePublicAccessBlock()` で 4 設定すべて true で投入。**`enforceTLSBucketPolicy()` で `aws:SecureTransport=false` を Deny するバケットポリシー（`Sid: TideDenyInsecureTransport`）を冪等にマージ適用**（純粋ロジック `BucketPolicyBuilder` + S3 シーム、`BucketPolicyBuilderTests` で固定）。適用はセットアップ時（ウィザード）＋起動時の両方で**冪等・非致命**（多層防御＝Tide 自身の通信は SDK が常に HTTPS。守るのは外部ツールの HTTP アクセス。`s3:Get/PutBucketPolicy` を IAM に追加・外しても同期は動く）。既存 statement は保持し Tide の statement だけ差し替える。残るは `PutBucketEncryption` でのバケットデフォルト暗号化のみ（**optional 据置き**＝per-object SSE-S3 を全経路で明示済みなので実害なし）。

**該当箇所（対応コード）:** SSE-S3 = `Tide/S3/S3Client.swift` の `putObject` / `createMultipartUpload`（ともに `serverSideEncryption: .aes256`）。プロビジョニング = 同ファイルの `enforcePublicAccessBlock` / `enforceTLSBucketPolicy` + 純粋マージ `Tide/S3/BucketPolicyBuilder.swift`。配線 = `Tide/UI/SetupWizardWindow.swift` の `finishProvisioning`（セットアップ時）と `Tide/App/AppEnvironment.swift` の `launchEngineFromCurrentConfig`（起動時・非致命）。

- `PutObjectInput` に `serverSideEncryption: .aes256`（または KMS）を指定していないため、バケット側でデフォルト暗号化が無いと**平文で保存**される（2023 以降の新規バケットは SSE-S3 がデフォルトだが明示すべき）。
- `createBucket` / `ensureLifecycleRules` で **`PutPublicAccessBlock` を発行していない**。ユーザが将来コンソール等で誤ってパブリック化するリスクをアプリ側で防げる（BlockPublicAcls / IgnorePublicAcls / BlockPublicPolicy / RestrictPublicBuckets を全部 true でセット）。
- `PutBucketEncryption` で SSE-S3 / SSE-KMS をデフォルト化するのも推奨。
- ~~`PutBucketPolicy` で `aws:SecureTransport=true` を強制（HTTPS 強制）するのも一般的。~~ → ✅ **対応済み（2026-06-23・#26）**。`aws:SecureTransport=false` を Deny するポリシーを `enforceTLSBucketPolicy()` で冪等適用（上記 Status 参照）。
