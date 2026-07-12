# tools/soak — soak（耐久受け入れ）支援ツール（Issue #40）

実 S3 での soak テスト（#40）のうち、**Mac 1 台で先行整備できる部分**を置く。
2 台目が来たら同じスクリプトを両端で回す。

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
```

### チェック内容

| 面 | 検出するズレ |
|---|---|
| index ↔ shards | 宣言済みシャードの不在（dangling）/ etag ドリフト / 未宣言シャード（ghost）/ エントリのシャード誤配置 |
| DB ↔ マニフェスト | 片側欠落 / sha256・size 不一致 |
| マニフェスト ↔ S3 実体 | 宣言実体の不在（現行 = 削除）/ size・etag 不一致 / 孤児オブジェクト |
| ローカル ↔ DB | 追跡ファイル不在 / size 不一致 / mtime 乖離（再アップロードループ因子・WARN）/ `--deep` で sha256 |
| 残骸 | tmp の `dl-*.part` / `restore-*.part`（1h 超）/ `transfer_state` 宙ぶらりん / `upload_queue` 滞留 |
| リソース | 本体・FP 拡張の RSS / FD 数（watch モードで時系列 JSONL） |

### 誤検出の抑制

- 同期進行中の過渡状態を誤検出しないため、DRIFT 候補が出たら `--recheck-delay`
  （デフォルト 90 秒 = poll 1 周期強）後に全パスを取り直し、**両方に現れた所見だけ** DRIFT にする。
- `upload_queue` に載っている path の片側欠落・不一致はアップロード待ちとして INFO に落とす。
- DB 未追跡のローカルファイル（除外対象・未同期）は INFO（`.DS_Store` 等）。

### 終了コード

`0` = 整合 / `1` = 持続する DRIFT あり / `2` = 実行エラー。

### 前提・注意

- S3 認証は **aws CLI の資格情報**（`--profile` 指定可）。アプリの Keychain には触れない。
- すべて読み取り専用（S3 は GET/LIST・DB は `mode=ro`・フォルダは stat のみ）。
- FP ボリューム（`~/Library/CloudStorage/Tide-Tide`）は突合対象外 — dataless が
  ハッシュ不能なため。FP 側の整合はマニフェスト経由で間接的に担保される。
- mtime WARN はマニフェストではなく **ローカル stat ↔ DB** の突合（[mtime 不変条件]）。
  編集直後の一過性は正常、恒常的に出るなら毎起動再アップロードループの兆候。
