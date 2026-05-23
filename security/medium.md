# 🟡 Medium

## M1. `Package.resolved` が `.gitignore` 対象

**Status:** ✅ Fixed (2026-05-24) — `.gitignore` から `Package.resolved` を除去し、コミット時の意図がわかるよう注記コメントを追加。

**該当箇所:** `.gitignore:22`

アプリケーション（ライブラリではない）では Package.resolved を**コミットすべき**。さもないと再ビルドのたびに依存パッケージのマイナー/パッチが浮動し、サプライチェーン上の再現性とインシデント追跡が壊れる。SBOM 出力やセキュリティスキャンの基盤としても必須。

---

## M2. `factoryReset` が DB ファイルを残す

**Status:** ✅ Fixed (2026-05-24) — `factoryReset` で `~/Library/Application Support/Tide` と `~/Library/Caches/Tide` をディレクトリごと削除し、`ConfigStore.resetIncludingDeviceId()` で deviceId も含めて UserDefaults をクリアするように変更。`make reset` と同じ挙動になる。

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

**Status:** ✅ Fixed (2026-05-24) — `S3Client.getObject(key:maxBytes:)` を追加。サーバ申告の `contentLength` で事前に弾き、受信完了後にも `data.count` を再チェックする二段構え。`getIndex` / `getShard` は 16 MiB、通常ダウンロードは既定 200 MiB（M1 上限の倍）。

**該当箇所:** `Tide/S3/S3Client.swift:219-242`

```swift
data = try await body.readData() ?? Data()
```

`getObject` は manifest 取得にも使われるが、攻撃者が `.tide/index.json` を 10 GB に膨らませれば、Tide はメモリ上に丸ごと吸い込みクラッシュする。M1 のローカル DoS 程度だが、ダウンロード経路（最大 5 並列 × ファイル）の memory pressure を上限化する意味で `maxBytes` を入れた方がよい（マニフェストは MiB オーダ上限で十分）。

---

## M5. アップロードのハッシュ計算とデータ読込が別 syscall（TOCTOU）

**Status:** ⏸ Deferred — M3（マルチパートアップロード）で `Uploader` をストリーミング化する際に併修予定。現状は SHA 不整合を検知して安全側に倒れるので、被害は「DB に記録された SHA が新バイトと食い違って次回スキャンで再アップロードされる」程度で、データ消失や任意書込みには繋がらない。

**該当箇所:** `Tide/S3/Uploader.swift:66-95`

`HashCalculator.sha256(of:)` でハッシュを取り、その後別途 `Data(contentsOf: fullURL)` で読み直してアップロードしている。間にファイルが書き換えられると、メタデータの sha256 と実バイトが食い違い、整合性検証（`Downloader.swift:42`）に失敗する。検知できるので安全側に倒れているが、**アップロード後の DB に古いハッシュが残る不整合**が起こりうる。

**対策:** ハッシュ計算をストリーミングで行いつつ同じバッファをアップロードに使う、または putObject 後に取得 ETag と「アップロードしたバイトから計算した sha256」を再検証してから DB 更新。
