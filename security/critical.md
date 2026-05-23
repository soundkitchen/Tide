# 🔴 Critical

## C1. パストラバーサル: リモートマニフェストがローカル任意パスへの書き込みを引き起こす

**Status:** ✅ Fixed (2026-05-24) — `Tide/Core/PathValidator.swift` を新設。`Downloader.download` / `applyRemoteDeletion` / `renameLocalForConflict`、`SyncEngine.reconcileRemoteEntry` / `performFullScan`、`Uploader.processUpload` / `processDelete` の各入口で `validateRelativePath` + `resolveSafely` を呼び、`..` / 絶対パス / NUL / バックスラッシュ / 空コンポーネントを拒否し、解決後 URL が `syncRoot` 配下に収まることも検証する。`ManifestReader.read` が manifest のキーを取り込む前にも検証する。

**該当箇所:** `Tide/S3/Downloader.swift:20-21, 76`、`Tide/Core/SyncEngine.swift:394`

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

**Status:** ✅ Fixed (2026-05-24) — `performFullScan` のウォーカーで `.isSymbolicLinkKey` を取得、symlink なら `skipDescendants()` してから `continue`。`Downloader` の書き込み先がシンボリックリンクなら拒否（リンク先実体の書き換えを防ぐ）。`applyRemoteDeletion` も symlink を削除対象から除外。

**該当箇所:** `Tide/Core/SyncEngine.swift:226-232`

```swift
let walker = fm.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey, ...],
    options: []
)
```

`FileManager.enumerator(at:)` は**ディレクトリへのシンボリックリンクを既定で辿る**。`syncRoot` 配下に `~/.ssh` を指すシンボリックリンクが置かれれば、その中身が S3 にアップロードされる。FileWatcher 側は `kFSEventStreamEventFlagItemIsSymlink` でスキップしている（`FileWatcher.swift:104`）が、全件スキャン経路では抜ける。

**対策:**
- enumerator の各 URL について `.isSymbolicLinkKey` を取り、シンボリックリンクは無視
- ディレクトリの場合は同様にチェックし、シンボリックリンクなら `walker.skipDescendants()`
- Downloader 側の `removeItem` / `moveItem` も、`fullURL` が既存のシンボリックリンクならエラーで弾く（リンク先実体の置換を防ぐ）

---

## C3. S3 サーバサイド暗号化が未指定 / バケットの Public Access Block 未設定

**Status:** 🟡 Partial (2026-05-24) — `putObject` に `serverSideEncryption: .aes256` を明示。プロビジョニング時に `enforcePublicAccessBlock()` で 4 設定すべて true で投入する（IAM ポリシーに `s3:PutBucketPublicAccessBlock` 追加済み）。`PutBucketEncryption` でのデフォルト暗号化と、`PutBucketPolicy` での `aws:SecureTransport=true` 強制は据置き。

**該当箇所:** `Tide/S3/Uploader.swift:90-95`、`Tide/S3/S3Client.swift:50-127`

- `PutObjectInput` に `serverSideEncryption: .aes256`（または KMS）を指定していないため、バケット側でデフォルト暗号化が無いと**平文で保存**される（2023 以降の新規バケットは SSE-S3 がデフォルトだが明示すべき）。
- `createBucket` / `ensureLifecycleRules` で **`PutPublicAccessBlock` を発行していない**。ユーザが将来コンソール等で誤ってパブリック化するリスクをアプリ側で防げる（BlockPublicAcls / IgnorePublicAcls / BlockPublicPolicy / RestrictPublicBuckets を全部 true でセット）。
- `PutBucketEncryption` で SSE-S3 / SSE-KMS をデフォルト化するのも推奨。
- `PutBucketPolicy` で `aws:SecureTransport=true` を強制（HTTPS 強制）するのも一般的。
