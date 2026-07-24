# tools/soak — soak（耐久受け入れ）支援ツール（Issue #40）

実 S3 での soak テスト（#40）のうち、**Mac 1 台で先行整備できる部分**を置く。
2 台目が来たら同じスクリプトを両端で回す。

M5 Phase 5 完了により FP 拡張が「1 台内の第 3 の書き手」になったため、1 台でも
「2 書き手の交錯 soak」が可能: `churn.py`（注入）と `consistency_check.py --watch`
（常時観測 = `make soak-watch`）を併走させる。

## consistency_check.py — 整合性突合 + 観測

「ローカル同期フォルダ ↔ ローカル DB ↔ S3 マニフェスト ↔ S3 実体」の 4 面を突合し、
残骸・宙ぶらりん・リソースを観測する。**アプリと独立した別実装**（マニフェストの
パース・シャード計算も再実装）なので、製品側のバグを同じバグで見逃さない。

```sh
# 単発チェック（設定は group defaults から自動解決）
python3 tools/soak/consistency_check.py          # または make soak-check

# ローカル全ファイルの SHA-256 まで突合（重い）
python3 tools/soak/consistency_check.py --deep

# 5 分間隔で回しっぱなし（JSONL を ~/Library/Logs/TideSoak/soak.jsonl に追記）
python3 tools/soak/consistency_check.py --watch 300

# FP-only 稼働モード用スコープ（後述）
python3 tools/soak/consistency_check.py --fp-only              # または make soak-check-fp
python3 tools/soak/consistency_check.py --fp-only --watch 300  # または make soak-watch-fp
```

### チェック内容

| 面 | 検出するズレ |
|---|---|
| index ↔ shards | 宣言済みシャードの不在（dangling）/ etag ドリフト / 未宣言シャード（ghost）/ エントリのシャード誤配置 |
| DB ↔ マニフェスト | 片側欠落 / sha256・size 不一致 |
| マニフェスト ↔ S3 実体 | 宣言実体の不在（現行 = 削除）/ size・etag 不一致 / 孤児オブジェクト |
| ローカル ↔ DB | 追跡ファイル不在 / size 不一致 / mtime 乖離（再アップロードループ因子・WARN）/ `--deep` で sha256 |
| shard_state ↔ shards | DB の etag キャッシュとシャード実体の不一致（pull 1 周期以内の stale は正常・持続すれば pull 停滞の兆候・WARN）/ 実在しないシャードのキャッシュ残存 |
| 残骸 | tmp の `dl-*.part` / `restore-*.part` / `s3restore-*.part`（1h 超）/ `transfer_state` 宙ぶらりん / `upload_queue` 滞留 |
| リソース | 本体・FP 拡張の RSS / FD 数（watch モードで時系列 JSONL・複数プロセス並存時は全 PID を記録） |

### 誤検出の抑制

- 同期進行中の過渡状態を誤検出しないため、DRIFT 候補が出たら `--recheck-delay` 後に
  全パスを取り直し、**両方に現れた所見だけ** DRIFT にする。デフォルトは **poll 間隔 + 30 秒**
  （group defaults の `tide.pollingIntervalSeconds`・未設定なら 180+30 = 210 秒）—
  リモート先行書込（2 台目 / FP 拡張）の pull 反映は最大 poll 1 周期かかるため、
  それより短いと正常な伝播遅延を DRIFT と誤検出する。
- `upload_queue` に載っている path の片側欠落・不一致はアップロード待ちとして INFO に落とす。
- DB 未追跡のローカルファイル（除外対象・未同期）は INFO（`.DS_Store` 等）。

### --fp-only — FP-only 稼働モード用スコープ（M5 Track B / B-3）

fpOnly（`ConfigStore.syncMode`）ではアプリが DB / 同期フォルダに触れない（凍結温存）ため、
通常スコープの突合は「凍結 DB vs 生きたマニフェスト」の比較になり偽 DRIFT を量産する。
`--fp-only` は突合面を S3 側だけに縮退する。切替後ライブ soak（#40 事後ゲート =
persistent DRIFT ゼロの実績）の観測係として `--watch` / cron で定期実行する。

- **残す**: index ↔ shards 構造整合 / マニフェスト ↔ S3 実体（孤児含む）/
  Caches tmp 残骸 / リソース観測（本体 + FP 拡張）。
- **落とす**: DB 系すべて（DB↔マニフェスト・ローカル↔DB・shard_state・`transfer_state`・
  `upload_queue`）と同期フォルダ走査。設定解決も sync-root / DB を必須にしない。
- **足す**: **DB 凍結見張り** — `db.sqlite` / `-wal` の mtime を stat だけで観測し、
  プロセス内の前回観測から前進したら WARN（DB 不在 → **新規出現**も含む。fpOnly 中に
  DB が書かれる = bootstrap 分岐のバグ = モード可逆性の要が壊れている疑い）。DB は
  開かない = 読み取り専用の維持。単発実行では観測窓が実行中しか無いため実効性があるのは
  `--watch` 常駐。保存モードが fpOnly のときだけ武装（folderSync 中の予行で正当な DB
  書込を誤報しない）。
- **モード切替の検出**: 実モード（`tide.syncMode`）は**毎周回再読**する。watch 常駐が
  モード切替を跨いだら `mode:switched` WARN で watch の再起動を案内（起動時スコープの
  まま偽 DRIFT / 偽 WARN を積み続けない）。凍結見張りは切替検出中は基準追従のみ。
  **正規手順は「切替の前後で soak-watch を停止 / 再起動」**（`docs/08` B-4 節の運用ルール）。
- **突合ガード**: 保存モード（group defaults の `tide.syncMode`）が fpOnly なのに
  `--fp-only` 無しで実行したら **exit 2**（偽 DRIFT の cron 誤発報を構造的に防ぐ）。
  逆（`--fp-only` × folderSync 設定）は切替前の予行として WARN + 続行。
  `--deep` とは併用不可（fpOnly はハッシュすべきローカル実体を持たない）= exit 2。
- watch の JSONL には `fp_only` フラグと（凍結見張り武装時）`db_mtime` が載る。

### 終了コード

`0` = 整合 / `1` = 持続する DRIFT あり / `2` = 実行エラー（設定解決不能・aws CLI 不在・
DB ロック・JSON 破損等、すべての実行時例外）。cron / loop では 1 だけを発報対象にできる。

### 前提・注意

- S3 認証は **aws CLI の資格情報**（`--profile` 指定可）。アプリの Keychain には触れない。
- すべて読み取り専用（S3 は GET/LIST・DB は `mode=ro`・フォルダは stat のみ）。
- FP ボリューム（`~/Library/CloudStorage/Tide-Tide`）は突合対象外 — dataless が
  ハッシュ不能なため。FP 側の整合はマニフェスト経由で間接的に担保される。
- mtime WARN はマニフェストではなく **ローカル stat ↔ DB** の突合（[mtime 不変条件]）。
  編集直後の一過性は正常、恒常的に出るなら毎起動再アップロードループの兆候。

## churn.py — 負荷注入（1 台加速 soak）

FSEvents 側同期フォルダと FP レプリカの両方へファイル操作を乱数注入し、
「アプリ書込 × FP 拡張書込」の交錯を 1 台で作る。**dev バケット前提**
（kill・競合・factoryReset 反復を注入する試験なので実データ・本番版履歴から隔離する）。

```sh
# 既定（group defaults の syncRoot + ~/Library/CloudStorage/Tide-Tide・Ctrl-C まで）
python3 tools/soak/churn.py            # または make soak-churn

# kill 注入込み・8 時間で終了
python3 tools/soak/churn.py --kill-app-every 300 --kill-ext-every 500 --duration-min 480

# 対象と設定の確認だけ（何も書かない）
python3 tools/soak/churn.py --dry-run
```

### 設計の要点

- **書込サイド 4 面**: `soak-churn-app/`（syncRoot 側のみ）・`soak-churn-fp/`（FP 側のみ）・
  `soak-churn-shared/`（**両サイドが同一相対パス空間へ書く** = 3-way 競合・`uploadConflict`・
  `.conflictThenDownload` を意図的に発火。台帳共有で一方が作ったファイルを他方が編集/削除する。
  `--no-cross-write` で無効化可）。
- **操作ミックス**: create / edit（上書き・追記）/ delete（30% で即再作成 = 削除→復元の交錯）/
  rename / dir 越し move / mkdir / **dir ごと move**（#67 実地回帰）/ **dir ごと削除**
  （FP 側は deleteItem(dir) 再帰 = `removeFileEntries` シャードバッチの soak カバレッジ・
  台帳既知 dir かつ配下 10 件以下限定・mkdir による dirs 成長の抑えも兼ねる）/
  read（FP 側 dataless の materialize 誘発）。`--multipart-every N`（既定 200）で
  20MB（16 MiB 閾値超）を投入。
- **台帳は `{相対パス: 概算サイズ}` の dict**（共有面はエイリアス共有 = **再代入禁止・
  インプレース更新のみ**）。`--max-total-mb` は生存ファイルの合計から算出＝ delete で正しく減る。
- **安全ガード**: 書込は専用サブツリー内限定（realpath 検証）・`--max-files`（500）・
  `--max-total-mb`（512）で有界・dotfile / `.syncignore` 名は生成しない・symlink 非生成非追従。
  competing 書込が作る競合コピーは台帳外（個別 op では触らないが、dir ごと削除（dir_delete）に
  同居分が巻き込まれることはある = サブツリー内なので安全・競合コピー掃除のカバレッジとして好都合。
  上限の概算外になる点は許容）。
- **再現性**: `--seed`（既定 40）+ 全操作 JSONL（`~/Library/Logs/TideSoak/churn.jsonl`）。
- **duty cycle**: `--active-min 50 --quiesce-min 10`（毎時 10 分の完全静穏窓で
  consistency_check の DRIFT 判定を確定させる）。
- **kill 注入**: `--kill-app-every` = `pkill -x Tide` → `open`（`--app-path`・リポジトリルートで
  実行する前提）・`--kill-ext-every` = 拡張 kill（fileproviderd がオンデマンド再起動）。
  マルチパート投入の直後スロットは転送中を狙って kill を優先スケジュール。
- **ネット断**（`--net-blip-every`・既定 OFF）: Wi-Fi（`--wifi-device`）を 30〜120 秒 OFF → ON。
  作業機の他用途を巻き込むため opt-in。**スリープ復帰は自動化しない**（復帰スケジュールに
  sudo が要り、スリープ中は本スクリプト自身も止まる）— 手動チェックリスト側で実施。
- **ENOENT の扱い**: 共有サブツリーでの「未伝播パスへの操作」は stale として記録し台帳保持
  （伝播後に再試行される）。専用サブツリーでの消失は台帳から除去。
- **後始末**: soak 終了後に各 `soak-churn-*` サブツリーを手で削除する（削除自体も
  削除伝播の最終テストになる）。
