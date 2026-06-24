# 🟠 High

## H1. Keychain 設定が暗黙のデフォルト依存

**Status:** ✅ Fixed (2026-05-24) — `KeychainStore` の共通クエリに `kSecUseDataProtectionKeychain=true`, `kSecAttrSynchronizable=false` を、attrs に `kSecAttrAccessible=kSecAttrAccessibleAfterFirstUnlock` と `kSecAttrLabel` を明示。Data Protection Keychain に寄せたので Bundle ID / Team ID 紐付けが厳格になり、`security` CLI からの素の覗き見も困難。

**追記 (2026-06-01):** Data Protection Keychain は `keychain-access-groups` entitlement が無いと実行時に `OSStatus 34018 (errSecMissingEntitlement)` で失敗する。`project.yml` の `entitlements` で `Tide/Tide.entitlements`（`keychain-access-groups: $(AppIdentifierPrefix)org.izukawa.Tide`）を付与し、`Makefile` に `-allowProvisioningUpdates` を追加して署名に埋め込むようにした。automatic signing の都合で **この Mac の開発者アカウントへのデバイス登録**（初回 Xcode GUI ビルドで自動）が前提（`docs/06-SETUP-AND-BUILD.md` 参照）。データ保護 Keychain の方針（本項）は維持。

**該当箇所:** `Tide/Storage/KeychainStore.swift:37-57`, `project.yml`（entitlements）, `Tide/Tide.entitlements`

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

AWS SDK のエラー記述には、リクエスト URL（バケット名・キー）、リージョン、稀にセッショントークンや署名のバイトが含まれる。`privacy: .public` だと**ユニファイドログに平文で永続化**され、後で `log show` から取得できる。対策前は同じ文字列が（当時の）`recentErrors` 配列に積まれメニューバー UI に表示されていた。現在は下記「残存 (F4)」のとおり構造化型 `recentIssues: [SyncIssue]` へ置換済みで、`privacy: .public` 補間もコードから一掃済み（grep 0 件）。

**対策:**
- `String(describing: error)` ではなく、`SyncError` への classify→短い理由文字列に置き換える
- ログは `privacy: .private`（または既定値）にし、`(reason)` のみ public に
- UI の `recentErrors` はクラス分けされたメッセージ（e.g. "AccessDenied on key X"）に絞る

**残存 (F4, 2026-06-01) ✅ Fixed (2026-06-11) — B 案で是正（M4 Sync Activity 対応に同梱）:**
上記対策の 3 点目を実装した。`recentErrors: [String]` を構造化型 **`recentIssues: [SyncIssue]`** に置換し、
UI の既定表示は **`SyncIssueClassifier`（`Tide/Core/SyncIssueClassifier.swift`・`S3ErrorClassifier`/`SyncError` を再利用）
の分類サマリ（ローカライズ済みカテゴリ + 行動指針）のみ**。生のエラー文字列は `SyncIssue.rawDetail` に隔離し、
行の context menu「Copy details」および Sync Activity ウィンドウの details 列で**オンデマンドにのみ**参照できる
（デバッグ性は保持＝B 案の意図どおり）。`status = .error(...)` も分類サマリ文字列に変更。sync_log への記録も
message は英語固定文・生エラーは details 列へ分離した。

**旧・残存内容（参考・解消済み）:** `SyncEngine.appendError("\(path): \(error)")` および
`status = .error(String(describing: error))` が生の SDK エラー文字列（バケット名・キー・リージョンを含み得る）を
`MenuBarContent`（`textSelection` 有効）へ表示し続けていた。

**脅威:** 攻撃者前提なしの情報露出。露出するのは**メタデータ**（バケット名・S3 キー＝同期ファイルのパス・リージョン）で、
**認証情報は含まない**（S3 エラー応答はエコーバックしない）。露出先は**本人画面のみ**で、API 経由のローカル読み出し経路は無い。
現実的な漏洩経路は「ユーザがエラーをスクショ／コピペで公開チャンネルに貼る」＋肩越し／画面共有。バケットは非公開
（Public Access Block 済み）なので名前を知られてもアクセス権は得られない。よって重要度は **Low（衛生寄り）**。

**保持の理由:** 生エラーは開発中のデバッグで実利が大きい。H2 で OS Log を `.private` 化したため `log show`（事後）は
伏字になり、`log stream --level debug`（リアルタイム）以外では UI が**事後コピーの実質唯一ソース**。現状は単一ユーザ
（＝開発者本人）運用で、漏洩経路も本人の管理下。

**再評価ゲートと是正方針:** **他人への配布／単一ユーザ開発を抜ける前に再評価する**。是正は単純削除（C 案: UI は短文のみ）
ではなく、**B 案＝「UI 既定は分類サマリ（`SyncError` classify→短い理由文字列）＋『詳細』をオンデマンドで展開/コピー」**
としてデバッグ性を保ったまま行う。再利用できる既存資産: `S3ErrorClassifier`（`Tide/S3/S3Client.swift`）/ `SyncError.description`。
対象: `Tide/Core/SyncEngine.swift` / `Tide/UI/MenuBarContent.swift`。

---

## H3. AWS 静的アクセスキーの長期保管

**Status:** 🟡 Mitigated (2026-05-24) — `docs/06-SETUP-AND-BUILD.md` に「静的キー流出時の被害」と最小権限ポリシーを必ずアタッチする旨を明記。`s3:PutBucketPublicAccessBlock` を最小権限ポリシーに追加。構造的な置き換え（STS / Identity Center）は将来課題として据置き。

設計上の話だが、`AccessKeyId / SecretAccessKey` をローカル Keychain に長期保持している。盗まれれば S3 バケット内ファイル全消去まで可能。

**緩和策（M2+ で検討）:**
- セットアップウィザードに、必要最小限の IAM ポリシー雛形（このバケットへの限定 `s3:Get/Put/Delete/List*`、`s3:GetBucketVersioning` 等のみ）をコピー可能で表示する
- 将来的に IAM Identity Center（旧 SSO）や STS AssumeRole への置き換えを視野に入れる
- ドキュメントに「このキーは MFA 必須ではないため、流出時の被害を最小化するためにポリシーを限定すること」を明記
