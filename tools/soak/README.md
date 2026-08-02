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

### launchd 常駐化 — 標準運用（Issue #84）

`--fp-only --watch` の駆動は **LaunchAgent 常駐が標準**（2026-07-25〜）。マシン再起動後の
「手動再開忘れ = 観測空白」（DB 凍結見張りも止まる）を構造的に防ぐ。ターミナル常駐
（`make soak-watch-fp`）は launchd を使わない環境・出力をリアルタイム目視したいデバッグ用の代替。

```sh
make soak-agent-install     # LaunchAgent 導入 + 開始（既定 300 秒間隔・再実行 = 再インストール）
make soak-agent-status      # state / PID / 直近 JSONL 1 行
make soak-agent-restart     # 再起動（モード切替ランブックの「watch 再起動」の正規手段）
make soak-agent-uninstall   # 解除（bootout + plist 削除）
```

- 実体は `tools/soak/soak_watch_agent.sh`。plist = `~/Library/LaunchAgents/org.izukawa.tide.soak-watch.plist`
  （`KeepAlive` + `RunAtLoad`・異常終了時は 60 秒スロットルで自動再起動）。
- **python3 / aws の実パス・PATH・`AWS_PROFILE` はインストール時のシェルから plist へ焼き込む**
  （launchd の既定 PATH に homebrew が無く aws CLI が見つからないため）。python3 / aws / リポジトリの
  パスを変えたら `make soak-agent-install` で再インストール。
- **インストールは既存の watch プロセス（ターミナル常駐）を検出すると中断する** — 併走すると
  同じ JSONL に二重追記され soak 実績の集計を汚すため。先にターミナル側を Ctrl-C で止める。
- ログ: JSONL は従来どおり `~/Library/Logs/TideSoak/soak.jsonl`。整形レポート（stdout）と
  実行エラー（stderr）は同ディレクトリの `agent.out.log` / `agent.err.log` へ（5 分間隔で
  月あたり十数 MB 程度・肥大したら手で消してよい。python は `-u` で起動 = 行バッファ相当・
  レポートが即書きされる）。
- **モード切替ランブックとの整合**: 切替時は「`make soak-agent-restart` で watch 再起動」が
  停止 → 再起動に相当（`mode:switched` WARN の案内どおりスコープ / 凍結見張りの基準を取り直す）。
  切替作業中に観測を完全に止めたい場合は `uninstall` → 作業 → `install`。

#### launchd 固有の TCC（初回導入時・実踏 2026-07-25）

- **初回スポーンで「"python3" が他のアプリケーションのデータへのアクセスを求めています」の
  ダイアログが出る → 「許可」する**。launchd 直下では python3（homebrew）自身が TCC の
  責任プロセスになり、group defaults / DB stat の読み取りが **Group Container 保護
  （`kTCCServiceSystemPolicyAppData`・macOS 15+）** に掛かるため。ターミナル実行
  （`make soak-watch-fp`）で通っていたのは Terminal.app への既存許可で、launchd には効かない。
- 拒否した / プロンプト未応答の間は、設定解決が
  `設定エラー: 解決できない設定があります … ['bucket', 'region']`（exit 2）で失敗し続け、
  launchd が 60 秒スロットルで再スポーンを繰り返す（`agent.err.log` で分かる）。誤って拒否したら
  システム設定 → プライバシーとセキュリティで python の許可を直すか、`tccutil reset` 後に再起動。
- **homebrew の python アップグレード後は再許可が要る場合がある**（許可はバイナリに紐づく）。
  `make soak-agent-status` で exit 2 ループに気づける。
- 既知の一過性: 並列 shard GET で aws CLI の SSO トークン更新が `Rate exceeded`（429）に
  なることがある。周回単位のエラーとして `agent.err.log` に `[ERROR]` 1 行が残り、
  次周回で自己回復する（watch ループは落ちない）。

#### watch 健全性通知（Issue #94）

launchd の KeepAlive は**プロセスの生存しか保証しない** — AWS 認証セッションの失効
（`login_session` は約 12 時間）などで周回が失敗し続けても `agent.err.log` に吐くだけで、
JSONL への追記が止まり**観測空白が静かに発生**する（#40 判定時、7 日中約 7 割が空白だった実害）。
`--watch` はこれを自分で検出して macOS 通知で可視化する（`WatchHealthNotifier`）:

- **連続 3 周回の失敗で初回通知**（300 秒間隔なら約 15 分。単発の 429 等では通知しない）。
  失敗が続く間は **1 時間ごとに再通知**、復帰した周回で**回復通知を 1 回**出す。
- 通知は可視化のみ — 周回の継続・終了コードには影響しない（`osascript` 自体の失敗も握りつぶす）。
- **通知を受けたらやること**: セッション失効なら `aws login`（対象 profile で）を再実行する。
  watch は次周回から自動復帰する（restart 不要）。原因が別（ネットワーク断等）なら
  `agent.err.log` の直近 `[ERROR]` を確認。
- 通知は osascript（スクリプトエディタ）名義で届く。表示されない場合はシステム設定 →
  通知で「スクリプトエディタ」（または osascript）の通知が許可されているか確認する。
- **運用推奨（ユーザ確定・設定済み 2026-08-03）**: 同設定で通知スタイルを**「持続的」**
  （旧称「通知パネル」/ Alerts）にする — 既定の「一時的」（バナー）は数秒で消えるため
  見逃しやすい。「持続的」なら閉じるまで画面右上に残り続け、「リアクションするまで表示」が
  通知センター機構のまま実現できる（コード側は不変更）。

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
