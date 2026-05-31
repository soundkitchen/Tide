# Tide セキュリティレビュー

レビュー対象: `main` ブランチ（初回コミット前）
レビュー日: 2026-05-24
スコープ: `Tide/` 配下の自前コード（依存ライブラリ・build 成果物は対象外）

## 対応サマリ（2026-05-24 適用後）

| ID | タイトル | ステータス |
|---|---|---|
| C1 | パストラバーサル | ✅ Fixed |
| C2 | symlink フォロー | ✅ Fixed |
| C3 | SSE / Public Access Block / HTTPS 強制 | 🟡 Partial — SSE + PublicAccessBlock 適用、HTTPS バケットポリシーは据置き |
| H1 | Keychain 属性 | ✅ Fixed |
| H2 | エラー詳細のログ露出 | ✅ Fixed |
| H3 | 静的キー長期保管 | 🟡 Mitigated — docs 注記のみ。構造的対応は将来 |
| M1 | Package.resolved コミット | ✅ Fixed |
| M2 | factoryReset のファイル残置 | ✅ Fixed |
| M3 | shardId 検証 | ✅ Fixed |
| M4 | getObject サイズ無制限 | ✅ Fixed（簡易: contentLength + 受信長の二段チェック） |
| M5 | アップロードの TOCTOU | ⏸ Deferred — M3 のマルチパート対応時に併修 |
| L1 | App Sandbox 無効 | 🟡 Partial — 死蔵キー除去のみ。Sandbox 化自体は M3+ |
| L2 | 機密ファイル除外 | ✅ Fixed |
| L3 | openSyncFolder URL 検証 | ✅ Fixed |
| L4 | UI 経由のエラー詳細 | ✅ Fixed（H2 と一括） |
| L5 | SHA1 のコメント | ✅ Fixed |
| L6 | DebounceQueue 競合 | ⏸ Deferred — `UPLOAD_QUEUE.UNIQUE(path)` で実害なしの想定で観察 |
| L7 | secretAccessKey の生存期間 | ✅ Fixed |
| L8 | `.syncignore`（リモート由来の除外パターン）の取り扱い | ✅ Fixed (2026-06-01) — 機密網は否定で覆せない / ReDoS・DoS 上限 / symlink 非追従 |

凡例: ✅ Fixed / 🟡 Partial / ⏸ Deferred

## 重要度別ファイル

| 重要度 | ファイル | 件数 |
|---|---|---|
| 🔴 Critical | [critical.md](critical.md) | 3 |
| 🟠 High | [high.md](high.md) | 3 |
| 🟡 Medium | [medium.md](medium.md) | 5 |
| 🟢 Low / Hardening | [low.md](low.md) | 8 |

## 当初の推奨対応順（参考）

1. **すぐ修正**: C1（パストラバーサル）／ C2（symlink フォロー）／ C3（SSE + Public Access Block）
2. **直近で修正**: H1（Keychain 属性）／ H2（ログ・UI 経由のエラー詳細露出）／ M3（shardId 検証）
3. **設計レビュー**: H3（静的キー運用）／ M1（Package.resolved コミット）／ L2（既定除外の充実）
4. **クリーンアップ**: M2（factoryReset）／ M4-5（DoS と TOCTOU）／ L1（サンドボックス方針）

C1 / C2 は単独で「他デバイス or バケット側書き込みできる第三者 → このマシン上の任意ファイル書き換え」に直結するので、機能追加（M2 マイルストーン）を進める前にここだけは確実に塞ぐべき。
