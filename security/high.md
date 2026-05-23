# 🟠 High

## H1. Keychain 設定が暗黙のデフォルト依存

**Status:** ✅ Fixed (2026-05-24) — `KeychainStore` の共通クエリに `kSecUseDataProtectionKeychain=true`, `kSecAttrSynchronizable=false` を、attrs に `kSecAttrAccessible=kSecAttrAccessibleAfterFirstUnlock` と `kSecAttrLabel` を明示。Data Protection Keychain に寄せたので Bundle ID / Team ID 紐付けが厳格になり、`security` CLI からの素の覗き見も困難。

**該当箇所:** `Tide/Storage/KeychainStore.swift:37-57`

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account
]
let attrs: [String: Any] = [kSecValueData as String: data]
```

- `kSecAttrAccessible` 未指定 → 新規追加時は `kSecAttrAccessibleWhenUnlocked`。ログイン直後の SyncEngine 起動には問題ないが、**明示すべき**。バックグラウンド常駐ならば `kSecAttrAccessibleAfterFirstUnlock` の方が適切。
- `kSecUseDataProtectionKeychain: true` を付けて**データ保護キーチェーン（iOS 互換）に寄せる**ことを強く推奨。macOS の古いファイルベース Keychain より ACL がチームID/Bundle ID にきちんと縛られ、`security` CLI からの素の覗き見も困難になる。
- `kSecAttrSynchronizable: false` を明示（iCloud Keychain 同期を防ぐ）。
- `SecItemUpdate` 系では `kSecAttrLabel` を入れて Keychain Access.app での識別を改善（任意）。

---

## H2. AWS エラー文字列を `privacy: .public` で OS Log に流している

**Status:** ✅ Fixed (2026-05-24) — `Tide/Core/SyncEngine.swift` / `Tide/Core/FileWatcher.swift` / `Tide/S3/Uploader.swift` / `Tide/S3/Downloader.swift` / `Tide/App/AppEnvironment.swift` の `privacy: .public` を一括 `.private` に置換。ユニファイドログには `<private>` で記録され、`log show` 由来の漏洩がなくなる。デバッグ時は `log stream --level debug` で従来通り読める。

**該当箇所:** 全体（`Tide/Core/SyncEngine.swift` 等）

```swift
AppLogger.sync.error("Full scan failed: \(String(describing: error), privacy: .public)")
```

AWS SDK のエラー記述には、リクエスト URL（バケット名・キー）、リージョン、稀にセッショントークンや署名のバイトが含まれる。`privacy: .public` だと**ユニファイドログに平文で永続化**され、後で `log show` から取得できる。さらに同じ文字列が `recentErrors` 配列に積まれ、メニューバー UI に表示されている（`SyncEngine.swift:657-660`、`MenuBarContent.swift:71-76`）。

**対策:**
- `String(describing: error)` ではなく、`SyncError` への classify→短い理由文字列に置き換える
- ログは `privacy: .private`（または既定値）にし、`(reason)` のみ public に
- UI の `recentErrors` はクラス分けされたメッセージ（e.g. "AccessDenied on key X"）に絞る

---

## H3. AWS 静的アクセスキーの長期保管

**Status:** 🟡 Mitigated (2026-05-24) — `docs/06-SETUP-AND-BUILD.md` に「静的キー流出時の被害」と最小権限ポリシーを必ずアタッチする旨を明記。`s3:PutBucketPublicAccessBlock` を最小権限ポリシーに追加。構造的な置き換え（STS / Identity Center）は将来課題として据置き。

設計上の話だが、`AccessKeyId / SecretAccessKey` をローカル Keychain に長期保持している。盗まれれば S3 バケット内ファイル全消去まで可能。

**緩和策（M2+ で検討）:**
- セットアップウィザードに、必要最小限の IAM ポリシー雛形（このバケットへの限定 `s3:Get/Put/Delete/List*`、`s3:GetBucketVersioning` 等のみ）をコピー可能で表示する
- 将来的に IAM Identity Center（旧 SSO）や STS AssumeRole への置き換えを視野に入れる
- ドキュメントに「このキーは MFA 必須ではないため、流出時の被害を最小化するためにポリシーを限定すること」を明記
