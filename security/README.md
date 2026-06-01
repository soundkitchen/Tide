# Tide セキュリティレビュー

レビュー対象: `main` ブランチ（初回コミット前）
レビュー日: 2026-05-24
スコープ: `Tide/` 配下の自前コード（依存ライブラリ・build 成果物は対象外）

## 再レビューのフォローアップ（2026-06-01）

現行コード全体の再レビューで検出した懸念。F1〜F3 は 2026-06-01 に対応（コード + テスト + ドキュメント）。F4 は**意図的に保持**（下記）。
各項目の詳細・対応内容・追加テストは参照先 md に記載する。

| ID | 重要度 | 概要 | 状態 | 参照 |
|---|---|---|---|---|
| F1 | Low〜Medium（可用性） | `.syncignore` の glob→正規表現が破滅的バックトラッキング（ReDoS）。当初の「ReDoS 回避済み」は過大記載だった | 🟡 Mitigated（速攻ガード。構造的解消は M3） | [low.md](low.md) L8/F1 |
| F2 | Medium | 祖先ディレクトリが symlink だとダウンロード書込が syncRoot 外へ抜ける（`resolveSafely` は字句検証のみ。C1/C2 の補完漏れ） | ✅ Fixed（`resolveForWrite` 新設） | [medium.md](medium.md) M6 |
| F3 | Low | `Uploader` が symlink 追従 API で読む。アップロード直前の symlink 再チェックが無い（TOCTOU、M5 と同根） | 🟡 Mitigated（直前再チェック。`O_NOFOLLOW` 化は M5/M3） | [low.md](low.md) L9 |
| F4 | Low | UI の `recentErrors` / `.error` が生エラー文字列を表示し続けている（H2 の UI 側残存） | ⏸ Deferred（意図的保持。配布前に再評価） | [high.md](high.md) H2 |

凡例: ✅ Fixed / 🟡 Mitigated / ⏸ Deferred / 🔴 未対応。深刻度は可用性・前提（攻撃者が S3 バケットを書ける必要があるか）を勘案した相対値。

F4 の据え置き理由: 生エラー文字列は開発中のデバッグで実利が大きく（H2 で OS Log は `.private` 化したため `log show` は伏字、UI が事後コピーの実質唯一ソース）、重要度も Low（露出はメタデータ＝バケット名・キー・リージョン、本人画面のみ、認証情報は含まない）。**他人への配布／単一ユーザ開発を抜ける前に再評価**し、その際は単純削除ではなく「UI は分類サマリ＋オンデマンドで詳細展開/コピー」案でデバッグ性を保ったまま是正する。

## 対応サマリ（2026-05-24 適用後）

| ID | タイトル | ステータス |
|---|---|---|
| C1 | パストラバーサル | ✅ Fixed |
| C2 | symlink フォロー | ✅ Fixed |
| C3 | SSE / Public Access Block / HTTPS 強制 | 🟡 Partial — SSE + PublicAccessBlock 適用、HTTPS バケットポリシーは据置き |
| H1 | Keychain 属性 | ✅ Fixed |
| H2 | エラー詳細のログ露出 | ✅ Fixed（UI 残は F4 として ⏸ Deferred・意図的保持） |
| H3 | 静的キー長期保管 | 🟡 Mitigated — docs 注記のみ。構造的対応は将来 |
| M1 | Package.resolved コミット | ✅ Fixed |
| M2 | factoryReset のファイル残置 | ✅ Fixed |
| M3 | shardId 検証 | ✅ Fixed |
| M4 | getObject サイズ無制限 | ✅ Fixed（簡易: contentLength + 受信長の二段チェック） |
| M5 | アップロードの TOCTOU | ⏸ Deferred — M3 のマルチパート対応時に併修（→ F3 も同根） |
| M6 | ダウンロード書込の祖先 symlink によるルート脱出 | ✅ Fixed（2026-06-01・F2。`PathValidator.resolveForWrite`） |
| L1 | App Sandbox 無効 | 🟡 Partial — 死蔵キー除去のみ。Sandbox 化自体は M3+ |
| L2 | 機密ファイル除外 | ✅ Fixed |
| L3 | openSyncFolder URL 検証 | ✅ Fixed |
| L4 | UI 経由のエラー詳細 | ✅ Fixed（H2 と一括） |
| L5 | SHA1 のコメント | ✅ Fixed |
| L6 | DebounceQueue 競合 | ⏸ Deferred — `UPLOAD_QUEUE.UNIQUE(path)` で実害なしの想定で観察 |
| L7 | secretAccessKey の生存期間 | ✅ Fixed |
| L8 | `.syncignore`（リモート由来の除外パターン）の取り扱い | 🟡 Partial / Mitigated — 機密網は否定で覆せない / symlink 非追従 / サイズ上限は維持。生成正規表現の ReDoS は速攻ガードで Mitigated（構造的解消は M3。→ F1） |
| L9 | アップロード読込が symlink 追従（読込時の再チェック無し） | 🟡 Mitigated（2026-06-01・F3。直前再チェック。`O_NOFOLLOW` 化は M5/M3） |

凡例: ✅ Fixed / 🟡 Partial / ⏸ Deferred / 🔴 未対応

## 重要度別ファイル

| 重要度 | ファイル | 件数 |
|---|---|---|
| 🔴 Critical | [critical.md](critical.md) | 3 |
| 🟠 High | [high.md](high.md) | 3 |
| 🟡 Medium | [medium.md](medium.md) | 6（M6 は 2026-06-01 に Fixed） |
| 🟢 Low / Hardening | [low.md](low.md) | 9（L9/F1 は 2026-06-01 に Mitigated） |

## 当初の推奨対応順（参考）

1. **すぐ修正**: C1（パストラバーサル）／ C2（symlink フォロー）／ C3（SSE + Public Access Block）
2. **直近で修正**: H1（Keychain 属性）／ H2（ログ・UI 経由のエラー詳細露出）／ M3（shardId 検証）
3. **設計レビュー**: H3（静的キー運用）／ M1（Package.resolved コミット）／ L2（既定除外の充実）
4. **クリーンアップ**: M2（factoryReset）／ M4-5（DoS と TOCTOU）／ L1（サンドボックス方針）

C1 / C2 は単独で「他デバイス or バケット側書き込みできる第三者 → このマシン上の任意ファイル書き換え」に直結するので、機能追加（M2 マイルストーン）を進める前にここだけは確実に塞ぐべき。
