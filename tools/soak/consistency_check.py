#!/usr/bin/env python3
"""Tide soak 整合性突合スクリプト（Issue #40 の 1 台先行分）。

「ローカル同期フォルダ ↔ ローカル DB ↔ S3 マニフェスト（.tide/index.json + shards/）
↔ S3 実体（files/ の現行バージョン）」の突合と、リソース・残骸の観測を行う。
アプリ（Tide.app）とは意図的に独立した別実装 — 製品側のバグを同じバグで見逃さないため、
マニフェストのパースやシャード計算もここで再実装している。

読み取り専用: S3 へは GET/LIST のみ、DB は mode=ro、同期フォルダは stat のみ。
S3 認証はアプリの Keychain ではなく aws CLI の資格情報（profile）を使う。

FP-only 稼働モード用スコープ（--fp-only・M5 Track B / B-3）: fpOnly はアプリが
DB / 同期フォルダに触れない（凍結温存）ため、通常スコープの突合は「凍結 DB vs
生きたマニフェスト」の比較になり偽 DRIFT を量産する。--fp-only は突合面を S3 側
（index↔shards 構造整合 + マニフェスト↔実体）だけに縮退し、DB 凍結の見張り
（mtime 前進 WARN・stat のみで DB は開かない）を足す。

一過性ノイズの抑制: 同期進行中のズレを誤検出しないため、疑いが出たら
--recheck-delay 秒後にもう一度だけ全パスを取り直し、両方に現れた所見だけを DRIFT として報告する。

終了コード: 0 = 整合 / 1 = 持続する DRIFT あり / 2 = 実行エラー。
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time

GROUP_CONTAINER = os.path.expanduser(
    "~/Library/Group Containers/G5G54TCH8W.org.izukawa.Tide"
)
GROUP_PLIST = os.path.join(
    GROUP_CONTAINER, "Library/Preferences/G5G54TCH8W.org.izukawa.Tide"
)
DEFAULT_DB = os.path.join(GROUP_CONTAINER, "Library/Application Support/Tide/db.sqlite")
CACHES_TMP = os.path.expanduser("~/Library/Caches/Tide/tmp")

# 所見の重さ。DRIFT のみが終了コードに影響する。
DRIFT, WARN, INFO = "DRIFT", "WARN", "INFO"


# ---------------------------------------------------------------- 設定解決

def defaults_read(key):
    """group defaults から 1 キー読む。未設定なら None。"""
    try:
        out = subprocess.run(
            ["defaults", "read", GROUP_PLIST, key],
            capture_output=True, text=True, encoding="utf-8", timeout=10,
        )
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def config_error(message):
    """設定エラーは exit 2（exit 1 = 持続 DRIFT と区別する・PR #62 レビュー中 1）。"""
    print(f"設定エラー: {message}", file=sys.stderr)
    sys.exit(2)


def polling_interval_seconds():
    """製品の poll 間隔。ConfigStore と同じく未設定/0 は 180 秒。"""
    raw = defaults_read("tide.pollingIntervalSeconds")
    try:
        v = int(raw) if raw else 0
    except ValueError:
        v = 0
    return v if v > 0 else 180


def resolve_config(args):
    bucket = args.bucket or defaults_read("tide.bucketName")
    region = args.region or defaults_read("tide.region")
    db_path = args.db or DEFAULT_DB
    saved_mode = defaults_read("tide.syncMode") or "folderSync"
    # 突合ガード: 保存モードが fpOnly なのに通常スコープで走らせると、凍結中の
    # DB / 同期フォルダを生きたマニフェストと比較して偽 DRIFT（exit 1 誤発報）になる。
    if saved_mode == "fpOnly" and not args.fp_only:
        config_error(
            "保存モードが fpOnly です — 通常スコープは凍結中の DB / 同期フォルダを"
            "生きたマニフェストと突合して偽 DRIFT になります。--fp-only を付けて"
            "ください（make soak-check-fp / soak-watch-fp）")
    missing = [n for n, v in [("bucket", bucket), ("region", region)] if not v]
    if args.fp_only:
        sync_root = None  # fpOnly では同期フォルダ・DB を必須にしない（凍結面は突合しない）
    else:
        sync_root = args.sync_root or defaults_read("tide.syncRootPath")
        if not sync_root:
            missing.append("sync-root")
    if missing:
        config_error(f"解決できない設定があります（group defaults 未設定 or 引数不足）: {missing}")
    if not args.fp_only:
        if not os.path.isdir(sync_root):
            config_error(f"同期フォルダが存在しません: {sync_root}")
        if not os.path.isfile(db_path):
            config_error(f"DB が存在しません: {db_path}")
    return {
        "bucket": bucket, "region": region, "sync_root": sync_root,
        "db": db_path, "profile": args.profile,
        "fp_only": args.fp_only, "saved_mode": saved_mode,
    }


# ---------------------------------------------------------------- aws CLI

def aws_cmd(cfg, *cmd):
    base = ["aws", "--region", cfg["region"]]
    if cfg["profile"]:
        base += ["--profile", cfg["profile"]]
    return base + list(cmd)


def aws_get_text(cfg, key):
    """S3 オブジェクトを文字列で取得。存在しなければ None。"""
    r = subprocess.run(
        aws_cmd(cfg, "s3", "cp", f"s3://{cfg['bucket']}/{key}", "-"),
        capture_output=True, text=True, encoding="utf-8", timeout=120,
    )
    if r.returncode != 0:
        if "NoSuchKey" in r.stderr or "404" in r.stderr:
            return None
        raise RuntimeError(f"S3 GET {key} failed: {r.stderr.strip()[:300]}")
    return r.stdout


def aws_list(cfg, prefix):
    """prefix 配下の現行バージョン一覧 {key: {size, etag}}（ページング対応）。"""
    result = {}
    token = None
    while True:
        cmd = ["s3api", "list-objects-v2", "--bucket", cfg["bucket"],
               "--prefix", prefix, "--output", "json"]
        if token:
            cmd += ["--continuation-token", token]
        r = subprocess.run(aws_cmd(cfg, *cmd), capture_output=True, text=True,
                           encoding="utf-8", timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"S3 LIST {prefix} failed: {r.stderr.strip()[:300]}")
        body = json.loads(r.stdout or "{}")
        for obj in body.get("Contents", []):
            result[obj["Key"]] = {
                "size": obj["Size"],
                "etag": obj.get("ETag", "").strip('"'),
            }
        if body.get("IsTruncated"):
            token = body.get("NextContinuationToken")
        else:
            return result


# ---------------------------------------------------------------- 各面のロード

def shard_id_of(path):
    """製品と同じ規則: SHA-1(path) 先頭 1 バイトの hex（ManifestSharding と独立に再実装）。"""
    return f"{hashlib.sha1(path.encode('utf-8')).digest()[0]:02x}"


def load_manifest(cfg, findings):
    """index + 全シャードを読み、({path: entry}, シャード実体一覧) を返す。構造整合の所見も積む。"""
    raw = aws_get_text(cfg, ".tide/index.json")
    if raw is None:
        findings.add(DRIFT, "manifest:index-missing", ".tide/index.json が存在しない")
        return {}, {}
    index = json.loads(raw)
    declared = index.get("shards", {})
    listed = aws_list(cfg, ".tide/shards/")

    # index 宣言 ↔ シャード実体の突合
    for sid, info in declared.items():
        key = f".tide/shards/{sid}.json"
        if key not in listed:
            findings.add(DRIFT, f"manifest:dangling-declaration:{sid}",
                         f"index が宣言するシャード {sid} が実在しない")
        elif listed[key]["etag"] != info.get("etag", "").strip('"'):
            findings.add(DRIFT, f"manifest:etag-drift:{sid}",
                         f"シャード {sid} の index 宣言 etag と実体 etag が不一致")
    for key in listed:
        sid = key.removeprefix(".tide/shards/").removesuffix(".json")
        if sid not in declared:
            findings.add(WARN, f"manifest:ghost-shard:{sid}",
                         f"index に宣言のないシャード実体 {key}（未宣言 = 全読者から不可視）")

    # 全シャードの entries を読む（並列 GET）
    entries = {}
    def fetch(sid):
        return sid, aws_get_text(cfg, f".tide/shards/{sid}.json")
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for sid, raw_shard in pool.map(fetch, sorted(declared.keys())):
            if raw_shard is None:
                continue  # dangling は上で所見化済み
            shard = json.loads(raw_shard)
            files = shard.get("files", {})
            if len(files) != declared[sid].get("count", -1):
                findings.add(INFO, f"manifest:count-mismatch:{sid}",
                             f"シャード {sid} の件数 {len(files)} が index 宣言 "
                             f"{declared[sid].get('count')} と不一致")
            for path, entry in files.items():
                if shard_id_of(path) != sid:
                    findings.add(DRIFT, f"manifest:misplaced:{path}",
                                 f"{path} がシャード {sid} に居る（正 = {shard_id_of(path)}）")
                entries[path] = entry
    return entries, listed


def load_db(cfg):
    con = sqlite3.connect(f"file:{cfg['db']}?mode=ro", uri=True, timeout=10)
    try:
        files = {r[0]: {"size": r[1], "mtime": r[2], "sha256": r[3], "version": r[4]}
                 for r in con.execute(
                     "SELECT path, size, mtime, sha256, s3_version_id FROM files")}
        transfers = list(con.execute(
            "SELECT path, direction, updated_at FROM transfer_state"))
        queue = list(con.execute(
            "SELECT path, operation, enqueued_at, attempts FROM upload_queue"))
        shard_cache = {r[0]: r[1] for r in con.execute(
            "SELECT shard_id, etag FROM shard_state")}
        return files, transfers, queue, shard_cache
    finally:
        con.close()


def scan_folder(root):
    """同期フォルダの {relpath: {size, mtime}}。.tide 配下と symlink は見ない（非追従）。"""
    result = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames
                       if d != ".tide" and not os.path.islink(os.path.join(dirpath, d))]
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            st = os.lstat(full)
            rel = os.path.relpath(full, root)
            result[rel] = {"size": st.st_size, "mtime": st.st_mtime}
    return result


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- fpOnly 凍結見張り

class DBFreezeWatch:
    """fpOnly の不変条件「アプリは DB を開かない = 書かない」の見張り（B-3）。

    db.sqlite / -wal の mtime を stat だけで観測し、プロセス内の前回観測から
    前進していたら WARN（DB は開かない = 読み取り専用の維持）。単発実行では
    観測窓が実行中しか無いため、実効性があるのは --watch 常駐運用。
    保存モードが fpOnly のときだけ武装する（folderSync 中の --fp-only 予行で
    正当な DB 書込を誤報しない）。DB 不在（クリーン環境）は無反応。
    """

    def __init__(self, db_path):
        self.db_path = db_path
        self.last = self.sample()

    def sample(self):
        latest = None
        for suffix in ("", "-wal"):
            try:
                m = os.lstat(self.db_path + suffix).st_mtime
            except FileNotFoundError:
                continue
            latest = m if latest is None else max(latest, m)
        return latest

    def check(self, findings):
        cur = self.sample()
        if self.last is not None and cur is not None and cur > self.last + 0.001:
            findings.add(WARN, "fp-freeze:db-advanced",
                         "fpOnly 凍結中のはずの DB（db.sqlite / -wal）の mtime が前進"
                         "（bootstrap 分岐のバグ = モード可逆性の要が壊れている疑い）")
        self.last = cur
        return cur


# ---------------------------------------------------------------- 所見の集約

class Findings:
    """key で同定できる所見の集まり。2 パスの積集合で一過性を除外する。"""

    def __init__(self):
        self.items = {}  # key -> (severity, message)

    def add(self, severity, key, message):
        self.items[key] = (severity, message)

    def merge_persistent(self, other):
        """両パスに現れた所見だけ残す（DRIFT の一過性除外）。WARN/INFO は 2 回目を採用。"""
        merged = Findings()
        for key, (sev, msg) in other.items.items():
            if sev == DRIFT and key not in self.items:
                merged.add(INFO, f"transient:{key}", f"一過性（2 回目のみ）: {msg}")
            else:
                merged.add(sev, key, msg)
        for key, (sev, msg) in self.items.items():
            if sev == DRIFT and key not in other.items:
                merged.add(INFO, f"transient:{key}", f"一過性（自己治癒）: {msg}")
        return merged

    def count(self, severity):
        return sum(1 for sev, _ in self.items.values() if sev == severity)


# ---------------------------------------------------------------- 突合パス

def check_tmp_remnants(tmp_dirs, findings, now):
    """tmp 残骸（1h 超の *.part）。s3restore- は B-2 の S3 内復元のクラッシュ残骸クラス。"""
    for tmp_dir in tmp_dirs:
        if not os.path.isdir(tmp_dir):
            continue
        for name in os.listdir(tmp_dir):
            if not name.startswith(("dl-", "restore-", "s3restore-")) \
               or not name.endswith(".part"):
                continue
            age = now - os.lstat(os.path.join(tmp_dir, name)).st_mtime
            if age > 3600:
                findings.add(WARN, f"tmp:remnant:{name}",
                             f"tmp 残骸（{age/3600:.1f}h 経過）: {tmp_dir}/{name}")


def run_pass(cfg, deep=False):
    findings = Findings()
    manifest, shard_objects = load_manifest(cfg, findings)
    s3_objects = aws_list(cfg, "files/")
    now = time.time()

    if cfg["fp_only"] and cfg["saved_mode"] != "fpOnly":
        findings.add(WARN, "mode:config-mismatch",
                     f"--fp-only 指定だが保存モードは {cfg['saved_mode']}"
                     "（切替前の予行なら想定どおり・DB / ローカル面は突合していない）")

    # --- マニフェスト ↔ S3 実体（現行バージョン）: 両モード共通 ---
    for path, entry in manifest.items():
        obj = s3_objects.get(f"files/{path}")
        if obj is None:
            findings.add(DRIFT, f"manifest-s3:missing:{path}",
                         f"マニフェスト宣言の実体が S3 に無い（現行 = 削除 or 不在）: {path}")
            continue
        if obj["size"] != entry.get("size"):
            findings.add(DRIFT, f"manifest-s3:size:{path}",
                         f"size 不一致（マニフェスト ↔ S3 現行）: {path}")
        elif entry.get("etag", "").strip('"') and obj["etag"] != entry["etag"].strip('"'):
            findings.add(DRIFT, f"manifest-s3:etag:{path}",
                         f"etag 不一致（S3 現行がマニフェストの版でない）: {path}")
    for key in s3_objects:
        path = key.removeprefix("files/")
        if path not in manifest:
            findings.add(WARN, f"s3-manifest:orphan:{path}",
                         f"S3 実体はあるがマニフェスト未宣言（孤児）: {path}")

    stats = {"manifest": len(manifest), "s3_objects": len(s3_objects)}
    tmp_dirs = [CACHES_TMP]

    if cfg["fp_only"]:
        # DB / 同期フォルダは凍結温存中 = 比較相手が生きていないため突合しない
        # （DB↔マニフェスト・ローカル↔DB・shard_state・transfer_state・upload_queue）。
        check_tmp_remnants(tmp_dirs, findings, now)
        return findings, stats

    db_files, transfers, queue, shard_cache = load_db(cfg)
    local = scan_folder(cfg["sync_root"])
    tmp_dirs.append(os.path.join(cfg["sync_root"], ".tide", "tmp"))

    pending_paths = {q[0] for q in queue}

    # --- DB ↔ マニフェスト ---
    for path, rec in db_files.items():
        entry = manifest.get(path)
        if entry is None:
            sev = INFO if path in pending_paths else DRIFT
            findings.add(sev, f"db-manifest:missing:{path}",
                         f"DB にあるがマニフェストに無い: {path}"
                         + ("（アップロード待ち）" if sev == INFO else ""))
            continue
        if rec["sha256"] != entry.get("sha256"):
            sev = INFO if path in pending_paths else DRIFT
            findings.add(sev, f"db-manifest:sha:{path}",
                         f"sha256 不一致（DB ↔ マニフェスト）: {path}")
        elif rec["size"] != entry.get("size"):
            findings.add(DRIFT, f"db-manifest:size:{path}",
                         f"size 不一致（DB ↔ マニフェスト）: {path}")
    for path in manifest:
        if path not in db_files:
            # リモート先行（pull 未着）は正常な過渡状態 → 2 パス持続なら DRIFT
            findings.add(DRIFT, f"manifest-db:missing:{path}",
                         f"マニフェストにあるが DB に無い（pull 未反映が持続）: {path}")

    # --- ローカル ↔ DB ---
    for path, rec in db_files.items():
        st = local.get(path)
        if st is None:
            sev = INFO if path in pending_paths else DRIFT
            findings.add(sev, f"db-local:missing:{path}",
                         f"DB 追跡ファイルがローカルに無い: {path}")
            continue
        if st["size"] != rec["size"]:
            sev = INFO if path in pending_paths else DRIFT
            findings.add(sev, f"db-local:size:{path}",
                         f"size 不一致（ローカル ↔ DB）: {path}")
            continue  # 内容が違うのは自明なので sha 再計算はしない
        if abs(st["mtime"] - rec["mtime"]) > 0.001:
            # [mtime 不変条件] の兆候（毎起動再アップロードループ因子）。編集直後は正常。
            sev = INFO if path in pending_paths else WARN
            findings.add(sev, f"db-local:mtime:{path}",
                         f"mtime 不一致（ローカル ↔ DB）: {path}")
        # deep は mtime 判定と独立に行う — mtime が乖離しているファイルこそ
        # 「stat で見えない内容乖離」を確認したい（PR #62 レビュー小 4）。
        if deep and sha256_of(os.path.join(cfg["sync_root"], path)) != rec["sha256"]:
            # アップロード待ち（size 同一・内容変更）は他の db-local 系と同様 INFO へ降格
            sev = INFO if path in pending_paths else DRIFT
            findings.add(sev, f"db-local:sha:{path}",
                         f"sha256 不一致（ローカル実体 ↔ DB）: {path}")
    untracked = [p for p in local if p not in db_files]
    if untracked:
        findings.add(INFO, "local:untracked",
                     f"DB 未追跡のローカルファイル {len(untracked)} 件"
                     f"（除外/未同期の可能性）: {sorted(untracked)[:5]}")

    # --- shard_state キャッシュ ↔ シャード実体（#40 観測項目「shard_state ドリフト」） ---
    # キャッシュなので pull 1 周期以内の stale は正常。持続すれば pull 停滞/取り込み漏れの兆候。
    for sid, cached_etag in shard_cache.items():
        obj = shard_objects.get(f".tide/shards/{sid}.json")
        if obj is None:
            findings.add(WARN, f"shard-state:orphan:{sid}",
                         f"shard_state に実在しないシャード {sid} のキャッシュが残存")
        elif cached_etag.strip('"') != obj["etag"]:
            findings.add(WARN, f"shard-state:stale:{sid}",
                         f"shard_state の etag がシャード実体と不一致（{sid}・"
                         "pull 1 周期以内なら正常・持続すれば pull 停滞の兆候）")

    # --- 残骸・宙ぶらりん ---
    check_tmp_remnants(tmp_dirs, findings, now)
    for path, direction, updated_at in transfers:
        age = now - updated_at
        if age > 3600:
            findings.add(WARN, f"transfer:stale:{direction}:{path}",
                         f"transfer_state 宙ぶらりん（{age/3600:.1f}h・{direction}）: {path}")
    for path, op, enqueued_at, attempts in queue:
        if attempts >= 5 or (now - enqueued_at) > 3600:
            findings.add(WARN, f"queue:stuck:{path}",
                         f"upload_queue 滞留（{op}・attempts={attempts}・"
                         f"{(now - enqueued_at)/3600:.1f}h）: {path}")

    stats.update({"db": len(db_files), "local": len(local),
                  "queue": len(queue), "transfers": len(transfers)})
    return findings, stats


# ---------------------------------------------------------------- リソース観測

def sample_resources():
    """Tide 本体と FP 拡張の RSS(KB)/FD 数。プロセス不在は None。
    複数一致（/Applications 側と build/ 側の並存等）は全 PID を記録する —
    先頭 1 つだけだと時系列が別プロセスに飛んでリーク検出がノイズ化する（PR #62 レビュー nit）。"""
    result = {}
    for label, pattern in [("app", "Tide.app/Contents/MacOS/Tide"),
                           ("extension", "TideFileProvider.appex")]:
        pid_out = subprocess.run(["pgrep", "-f", pattern],
                                 capture_output=True, text=True, encoding="utf-8")
        pids = [p for p in pid_out.stdout.split() if p.isdigit()]
        if not pids:
            result[label] = None
            continue
        samples = []
        for pid in pids:
            rss = subprocess.run(["ps", "-o", "rss=", "-p", pid],
                                 capture_output=True, text=True,
                                 encoding="utf-8").stdout.strip()
            fd = subprocess.run(["lsof", "-p", pid], capture_output=True,
                                text=True, encoding="utf-8")
            samples.append({
                "pid": int(pid),
                "rss_kb": int(rss) if rss.isdigit() else None,
                "fd": max(0, len(fd.stdout.splitlines()) - 1),
            })
        result[label] = samples
    return result


# ---------------------------------------------------------------- 実行・出力

def format_report(findings, stats, resources, fp_only=False):
    lines = []
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    counts = {s: findings.count(s) for s in (DRIFT, WARN, INFO)}
    verdict = "整合 OK" if counts[DRIFT] == 0 else f"DRIFT {counts[DRIFT]} 件"
    if fp_only:
        verdict = f"fp-only {verdict}"
    seg = " / ".join(f"{label} {stats[key]}" for key, label in
                     [("manifest", "manifest"), ("db", "db"),
                      ("local", "local"), ("s3_objects", "s3")] if key in stats)
    lines.append(f"[{ts}] {verdict}  "
                 f"(warn {counts[WARN]} / info {counts[INFO]})  {seg} 件")
    for label in ("app", "extension"):
        samples = resources.get(label)
        if not samples:
            lines.append(f"  {label}: 非稼働")
            continue
        for s in samples:
            rss = f"{s['rss_kb']/1024:.1f}MB" if s["rss_kb"] is not None else "?"
            lines.append(f"  {label}: pid {s['pid']}  rss {rss}  fd {s['fd']}")
    order = {DRIFT: 0, WARN: 1, INFO: 2}
    for key, (sev, msg) in sorted(findings.items.items(),
                                  key=lambda kv: (order[kv[1][0]], kv[0])):
        lines.append(f"  [{sev}] {msg}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bucket", help="S3 バケット名（省略時 group defaults）")
    ap.add_argument("--region", help="S3 リージョン（省略時 group defaults）")
    ap.add_argument("--sync-root", help="同期フォルダ（省略時 group defaults）")
    ap.add_argument("--db", help=f"DB パス（省略時 {DEFAULT_DB}）")
    ap.add_argument("--profile", help="aws CLI プロファイル")
    ap.add_argument("--deep", action="store_true",
                    help="ローカル全ファイルを SHA-256 再計算して DB と突合（重い）")
    ap.add_argument("--fp-only", action="store_true",
                    help="FP-only 稼働モード用スコープ（Track B / B-3）: S3 面"
                         "（index↔shards / マニフェスト↔実体）のみ突合し、凍結中の"
                         " DB / 同期フォルダには触れない。DB 凍結見張り"
                         "（mtime 前進 WARN）付き")
    ap.add_argument("--recheck-delay", type=int, default=None,
                    help="DRIFT 検出時の再確認までの秒数。デフォルトは poll 間隔 + 30"
                         "（group defaults の tide.pollingIntervalSeconds・未設定なら 180+30=210）。"
                         "リモート先行書込の pull 反映は最大 poll 1 周期かかるため、"
                         "それより短いと正常な伝播遅延を DRIFT と誤検出する")
    ap.add_argument("--watch", type=int, metavar="SEC",
                    help="SEC 秒間隔で回し続け、JSONL を --log に追記する")
    ap.add_argument("--log", default=os.path.expanduser(
        "~/Library/Logs/TideSoak/soak.jsonl"), help="watch モードの JSONL 出力先")
    args = ap.parse_args()
    if args.fp_only and args.deep:
        config_error("--deep は --fp-only と併用できません（fpOnly はローカル実体を突合しない）")
    cfg = resolve_config(args)
    if args.recheck_delay is None:
        args.recheck_delay = polling_interval_seconds() + 30
    # 凍結見張りは実モードが fpOnly のときだけ武装（予行 = folderSync 中は正当な DB 書込がある）
    freeze = DBFreezeWatch(cfg["db"]) \
        if cfg["fp_only"] and cfg["saved_mode"] == "fpOnly" else None

    def one_round():
        findings, stats = run_pass(cfg, deep=args.deep)
        if findings.count(DRIFT) > 0:
            print(f"  … DRIFT 候補 {findings.count(DRIFT)} 件 → "
                  f"{args.recheck_delay}s 後に再確認（一過性除外）", file=sys.stderr)
            time.sleep(args.recheck_delay)
            second, stats = run_pass(cfg, deep=args.deep)
            findings = findings.merge_persistent(second)
        if freeze:
            freeze.check(findings)
        resources = sample_resources()
        print(format_report(findings, stats, resources, fp_only=cfg["fp_only"]))
        return findings, stats, resources

    if not args.watch:
        findings, _, _ = one_round()
        sys.exit(1 if findings.count(DRIFT) > 0 else 0)

    os.makedirs(os.path.dirname(args.log), exist_ok=True)
    print(f"watch モード: {args.watch}s 間隔・ログ = {args.log}（Ctrl-C で終了）")
    while True:
        try:
            findings, stats, resources = one_round()
            record = {
                "ts": datetime.datetime.now().isoformat(timespec="seconds"),
                "fp_only": cfg["fp_only"],
                "drift": findings.count(DRIFT), "warn": findings.count(WARN),
                "info": findings.count(INFO), "stats": stats,
                "resources": resources,
                **({"db_mtime": freeze.last} if freeze else {}),
                "findings": [
                    {"severity": sev, "key": key, "message": msg}
                    for key, (sev, msg) in findings.items.items() if sev != INFO
                ],
            }
            with open(args.log, "a") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
        except KeyboardInterrupt:
            raise
        except Exception as e:
            print(f"[ERROR] {e}", file=sys.stderr)
        time.sleep(args.watch)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as e:
        # 実行エラー（aws CLI 不在 / DB ロック / JSON 破損 / タイムアウト等）はすべて exit 2 —
        # exit 1 = 「持続 DRIFT」と区別し、cron/loop 運用での誤発報を防ぐ（PR #62 レビュー中 1）。
        print(f"実行エラー: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
