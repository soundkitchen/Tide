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

**Status:** ⏸ Deferred — `upload_queue` テーブルの `UNIQUE(path)` 制約により、同一パスの並列処理が衝突しても DB レベルで重複が collapse される。実害（DB 整合性破壊）は出ない想定。観察を継続し、再現したら handler 側に in-flight 集約を入れる。

**該当箇所:** `Tide/Core/DebounceQueue.swift:45-52`

actor 内で `Task.detached` を `for` ループから発火している。`emitter` 側で長時間ブロックすると同時実行が起きるため、SyncEngine 側で同じ key の処理が**並列に走り得る**ことを念頭に置く必要がある（Uploader は同じ path への upload/delete が 5 並列タスクから同時に走るケース）。実害（= DB 整合性破壊）はなさそうだが、UploadQueueRecord に対する `.replace`/`.delete` の order が崩れる可能性は要確認。

---

## L7. メモリ上の `secretAccessKey` の生存期間

**Status:** ✅ Fixed (2026-05-24) — `SetupWizardWindow.runStartSyncing` 成功直後に `accessKeyId` / `secretAccessKey` を `""` で参照切断。Swift `String` のヒープ実体は GC 任せだが、ライブなオブジェクトグラフからは外れる。

**該当箇所:** `Tide/UI/SetupWizardWindow.swift:11`

SwiftUI の `@State private var secretAccessKey: String = ""` は SetupWizardWindow がディスポーズされるまで残り、`String` は zeroize できない。仕様上不可避だが、`runStartSyncing` 完了直後に `secretAccessKey = ""` を代入して参照を切る程度は意味がある（残留はあくまでヒープ任せだが、ライブなオブジェクトグラフからは切れる）。

---

## L8. `.syncignore`（リモート由来の除外パターン）の取り扱い

**Status:** ✅ Fixed (2026-06-01) — M3 で `.syncignore` 対応を追加。リモート（S3）から伝播し得るユーザパターンが、ローカル FS 判定に影響することを踏まえた防御を入れた。

**該当箇所:** `Tide/Core/SyncIgnoreMatcher.swift` / `Tide/Core/IgnoreDecision.swift` / `Tide/Core/SyncEngine.swift`

- **機密網は否定 `!` で覆せない**: `IgnoreDecision.shouldSkip` はハードコード除外（`HardcodedIgnoreRules`）を最優先で評価し、`.syncignore` のユーザパターン（否定含む）より常に優先する。悪意ある / 壊れたリモート `.syncignore` に `!.env` 等を書かれても、`.env` などの機密ファイルが同期対象に戻ることはない。
- **ReDoS / DoS 回避**: ユーザ正規表現は受け取らず、グロブから境界付き正規表現を生成。ファイルサイズ上限 256 KB / パターン数上限 10,000 で、巨大 / 大量パターンによる資源枯渇を防ぐ。
- **読込経路の安全性**: `.syncignore` の読込は `PathValidator.resolveSafely(relativePath: ".syncignore", syncRoot:)` 経由で、シンボリックリンクは追従しない。
- **影響の上限**: リモート由来パターンができるのは「除外」か（否定での）「再包含」のみ。再包含してもハードコード除外は覆せないため、最悪でも「同期されるべきファイルが同期されない（可用性）」に留まり、機密漏洩には繋がらない。
