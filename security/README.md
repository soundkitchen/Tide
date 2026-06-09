# Tide セキュリティレビュー

レビュー対象: `main` ブランチ（初回コミット前）
レビュー日: 2026-05-24
スコープ: `Tide/` 配下の自前コード（依存ライブラリ・build 成果物は対象外）

## M3 マルチパートブランチのコードレビュー（2026-06-02）

`feature/m3-multipart`（M3 サブA: マルチパート + ストリーミング + 1 ファイルアップロード上限）の差分を `xhigh` 効率でレビュー。`docs/` 仕様レベルではなく実装の正当性・可用性に絞った結果、**セキュリティ/可用性に関係する未対応項目を 3 件**記録する（純粋なコード整理＝etag 重複・hex 再利用・Picker ラベル・404 判定の三重化・`ConfigStore` の `0` 多義性などは security 対象外として除外）。**取捨選択は別スレッドで行う**前提で、ここでは状態を 🔴 未対応 とし honest severity を付す。

| ID | 重要度 | 概要 | 状態 | 参照 |
|---|---|---|---|---|
| M7 | Medium（可用性） | 復元経路 `downloadToFile` がサイズ無制限（`maxBytes=nil`）。M4 の 200 MiB cap が新経路で失効＝マニフェスト改ざんでローカルディスク枯渇 | ✅ Fixed (2026-06-02) | [medium.md](medium.md) M7 |
| L10 | Low（可用性） | マルチパート中の「その場切り詰め」で空/過小パート → `CompleteMultipartUpload` 失敗 → リトライ空振り（自己回復・整合性は SHA で担保） | ✅ Fixed (2026-06-02) | [low.md](low.md) L10 |
| L11 | Low（資源） | 巨大ファイルのパートが肥大（5 TiB→583 MiB/部）し常駐メモリ ~2.3 GiB。`PartPlan` の防御ループはデッドコード | ✅ Fixed (2026-06-02) | [low.md](low.md) L11 |

凡例: ✅ Fixed / 🟡 Mitigated / ⏸ Deferred / 🔴 未対応。M7 は C1/M4 と同じ前提（攻撃者がバケットを書ける）での可用性低下。L10/L11 は攻撃者起因ではなく局所変更・自己資源の問題で Low。**3 件とも本スレッドで対応済み（2026-06-02）**: M7=復元に `maxBytes: entry.size`、L10=空 parts ガード（`completeMultipartUpload` と `MultipartUploader`）、L11=`PartPlan` の `maxPartSize`（64MiB）cap + デッドループを直接 floor 計算に置換。

## 再レビューのフォローアップ（2026-06-01）

現行コード全体の再レビューで検出した懸念。F1〜F3 は 2026-06-01 に対応（コード + テスト + ドキュメント）。F1 は当初速攻ガードで Mitigated 止まりだったが、**2026-06-04 に線形時間グロブ照合への置換で構造的に解消（Fixed）**。F4 は**意図的に保持**（下記）。
各項目の詳細・対応内容・追加テストは参照先 md に記載する。

| ID | 重要度 | 概要 | 状態 | 参照 |
|---|---|---|---|---|
| F1 | Low〜Medium（可用性） | `.syncignore` の glob→正規表現が破滅的バックトラッキング（ReDoS）。当初の「ReDoS 回避済み」は過大記載だった | ✅ Fixed（線形時間グロブ照合に置換。2026-06-04） | [low.md](low.md) L8/F1 |
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
| M5 | アップロードの TOCTOU | ✅ Fixed（2026-06-02・M3。`NoFollowFileReader` で `O_NOFOLLOW` 単一 FD 化。→ F3 / L9 も同根で一括） |
| M6 | ダウンロード書込の祖先 symlink によるルート脱出 | ✅ Fixed（2026-06-01・F2。`PathValidator.resolveForWrite`） |
| M7 | 復元ストリーミングのサイズ無制限（M4 の回帰） | ✅ Fixed（2026-06-02。2026-06-04 サブ D-D3 で機構を `Downloader` sink の `total > entry.size` 判定へ移動） |
| L1 | App Sandbox 無効 | 🟡 Partial — 死蔵キー除去のみ。Sandbox 化自体は M3+ |
| L2 | 機密ファイル除外 | ✅ Fixed |
| L3 | openSyncFolder URL 検証 | ✅ Fixed |
| L4 | UI 経由のエラー詳細 | ✅ Fixed（H2 と一括） |
| L5 | SHA1 のコメント | ✅ Fixed |
| L6 | 書込中ファイルの torn upload + in-flight collapse | ✅ Fixed（2026-06-09・PR #14。真因 2 件: ① 完了/失敗処理の `path` 基準削除 → id 基準に統一、② 成長中ファイルの torn read → 安定化ゲート `StabilityCheck`（A-detect）+ 不安定ファイルの延期/可視化。当初疑った `DebounceQueue.fire` 並行は無関係と判明） |
| L7 | secretAccessKey の生存期間 | ✅ Fixed |
| L8 | `.syncignore`（リモート由来の除外パターン）の取り扱い | ✅ Fixed — 機密網は否定で覆せない / symlink 非追従 / サイズ上限は維持。生成正規表現の ReDoS は線形時間グロブ照合への置換で構造的に解消（2026-06-04。→ F1） |
| L9 | アップロード読込が symlink 追従（読込時の再チェック無し） | ✅ Fixed（2026-06-02・M3。`NoFollowFileReader` で `O_NOFOLLOW` 単一 FD 化） |
| L10 | マルチパート中の切り詰めで CompleteMultipartUpload 失敗 | ✅ Fixed（2026-06-02・空 parts ガード × 2） |
| L11 | 巨大ファイルのパート肥大による常駐メモリ増 | ✅ Fixed（2026-06-02・`maxPartSize` 64MiB cap + デッドコード整理） |
| L12 | 中断・再開（transfer_state / Range / 決定的 tmp）の攻撃面 | ✅ Reviewed（2026-06-05・M3 サブ D。tmp_path 再計算照合 / 再開時 symlink 破棄 / SHA ゲート / 起動時オーファン掃除） |

凡例: ✅ Fixed / 🟡 Partial / ⏸ Deferred / 🔴 未対応

## 重要度別ファイル

| 重要度 | ファイル | 件数 |
|---|---|---|
| 🔴 Critical | [critical.md](critical.md) | 3 |
| 🟠 High | [high.md](high.md) | 3 |
| 🟡 Medium | [medium.md](medium.md) | 7（M6 Fixed / M7 は 2026-06-02 検出・未対応） |
| 🟢 Low / Hardening | [low.md](low.md) | 12（L12 = M3 サブ D 中断・再開の攻撃面・2026-06-05 Reviewed） |

## 当初の推奨対応順（参考）

1. **すぐ修正**: C1（パストラバーサル）／ C2（symlink フォロー）／ C3（SSE + Public Access Block）
2. **直近で修正**: H1（Keychain 属性）／ H2（ログ・UI 経由のエラー詳細露出）／ M3（shardId 検証）
3. **設計レビュー**: H3（静的キー運用）／ M1（Package.resolved コミット）／ L2（既定除外の充実）
4. **クリーンアップ**: M2（factoryReset）／ M4-5（DoS と TOCTOU）／ L1（サンドボックス方針）

C1 / C2 は単独で「他デバイス or バケット側書き込みできる第三者 → このマシン上の任意ファイル書き換え」に直結するので、機能追加（M2 マイルストーン）を進める前にここだけは確実に塞ぐべき。
