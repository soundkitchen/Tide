#!/usr/bin/env python3
"""Tide soak 整合性突合スクリプト（Issue #40 の 1 台先行分）。

「ローカル同期フォルダ ↔ ローカル DB ↔ S3 マニフェスト（.tide/index.json + shards/）
↔ S3 実体（files/ の現行バージョン）」の突合と、リソース・残骸の観測を行う。
アプリ（Tide.app）とは意図的に独立した別実装 — 製品側のバグを同じバグで見逃さないため、
マニフェストのパースやシャード計算もここで再実装している。

読み取り専用: S3 へは GET/LIST のみ、DB は mode=ro、同期フォルダは stat のみ。
S3 認証はアプリの Keychain ではなく aws CLI の資格情報（profile）を使う。

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
            capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def resolve_config(args):
    bucket = args.bucket or defaults_read("tide.bucketName")
    region = args.region or defaults_read("tide.region")
    sync_root = args.sync_root or defaults_read("tide.syncRootPath")
    db_path = args.db or DEFAULT_DB
    missing = [n for n, v in
               [("bucket", bucket), ("region", region), ("sync-root", sync_root)] if not v]
    if missing:
        sys.exit(f"設定を解決できません（group defaults 未設定 or 引数不足）: {missing}")
    if not os.path.isdir(sync_root):
        sys.exit(f"同期フォルダが存在しません: {sync_root}")
    if not os.path.isfile(db_path):
        sys.exit(f"DB が存在しません: {db_path}")
    return {
        "bucket": bucket, "region": region, "sync_root": sync_root,
        "db": db_path, "profile": args.profile,
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
        capture_output=True, text=True, timeout=120,
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
        r = subprocess.run(aws_cmd(cfg, *cmd), capture_output=True, text=True, timeout=120)
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
    """index + 全シャードを読み、{path: entry} を返す。構造整合の所見も積む。"""
    raw = aws_get_text(cfg, ".tide/index.json")
    if raw is None:
        findings.add(DRIFT, "manifest:index-missing", ".tide/index.json が存在しない")
        return {}
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
    return entries


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
        return files, transfers, queue
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

def run_pass(cfg, deep=False):
    findings = Findings()
    manifest = load_manifest(cfg, findings)
    db_files, transfers, queue = load_db(cfg)
    local = scan_folder(cfg["sync_root"])
    s3_objects = aws_list(cfg, "files/")
    now = time.time()

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

    # --- マニフェスト ↔ S3 実体（現行バージョン） ---
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
        elif abs(st["mtime"] - rec["mtime"]) > 0.001:
            # [mtime 不変条件] の兆候（毎起動再アップロードループ因子）。編集直後は正常。
            sev = INFO if path in pending_paths else WARN
            findings.add(sev, f"db-local:mtime:{path}",
                         f"mtime 不一致（ローカル ↔ DB）: {path}")
        elif deep and sha256_of(os.path.join(cfg["sync_root"], path)) != rec["sha256"]:
            findings.add(DRIFT, f"db-local:sha:{path}",
                         f"sha256 不一致（ローカル実体 ↔ DB）: {path}")
    untracked = [p for p in local if p not in db_files]
    if untracked:
        findings.add(INFO, "local:untracked",
                     f"DB 未追跡のローカルファイル {len(untracked)} 件"
                     f"（除外/未同期の可能性）: {sorted(untracked)[:5]}")

    # --- 残骸・宙ぶらりん ---
    for tmp_dir in [CACHES_TMP, os.path.join(cfg["sync_root"], ".tide", "tmp")]:
        if not os.path.isdir(tmp_dir):
            continue
        for name in os.listdir(tmp_dir):
            if not (name.startswith("dl-") or name.startswith("restore-")) \
               or not name.endswith(".part"):
                continue
            age = now - os.lstat(os.path.join(tmp_dir, name)).st_mtime
            if age > 3600:
                findings.add(WARN, f"tmp:remnant:{name}",
                             f"tmp 残骸（{age/3600:.1f}h 経過）: {tmp_dir}/{name}")
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

    stats = {"manifest": len(manifest), "db": len(db_files), "local": len(local),
             "s3_objects": len(s3_objects), "queue": len(queue),
             "transfers": len(transfers)}
    return findings, stats


# ---------------------------------------------------------------- リソース観測

def sample_resources():
    """Tide 本体と FP 拡張の RSS(KB)/FD 数。プロセス不在は None。"""
    result = {}
    for label, pattern in [("app", "Tide.app/Contents/MacOS/Tide"),
                           ("extension", "TideFileProvider.appex")]:
        pid_out = subprocess.run(["pgrep", "-f", pattern],
                                 capture_output=True, text=True)
        pids = [p for p in pid_out.stdout.split() if p.isdigit()]
        if not pids:
            result[label] = None
            continue
        pid = pids[0]
        rss = subprocess.run(["ps", "-o", "rss=", "-p", pid],
                             capture_output=True, text=True).stdout.strip()
        fd = subprocess.run(["lsof", "-p", pid], capture_output=True, text=True)
        result[label] = {
            "pid": int(pid),
            "rss_kb": int(rss) if rss.isdigit() else None,
            "fd": max(0, len(fd.stdout.splitlines()) - 1),
        }
    return result


# ---------------------------------------------------------------- 実行・出力

def format_report(findings, stats, resources):
    lines = []
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    counts = {s: findings.count(s) for s in (DRIFT, WARN, INFO)}
    verdict = "整合 OK" if counts[DRIFT] == 0 else f"DRIFT {counts[DRIFT]} 件"
    lines.append(f"[{ts}] {verdict}  "
                 f"(warn {counts[WARN]} / info {counts[INFO]})  "
                 f"manifest {stats['manifest']} / db {stats['db']} / "
                 f"local {stats['local']} / s3 {stats['s3_objects']} 件")
    for label in ("app", "extension"):
        r = resources.get(label)
        lines.append(f"  {label}: " + (
            f"pid {r['pid']}  rss {r['rss_kb']/1024:.1f}MB  fd {r['fd']}" if r else "非稼働"))
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
    ap.add_argument("--recheck-delay", type=int, default=90,
                    help="DRIFT 検出時の再確認までの秒数（デフォルト 90 = poll 1 周期強）")
    ap.add_argument("--watch", type=int, metavar="SEC",
                    help="SEC 秒間隔で回し続け、JSONL を --log に追記する")
    ap.add_argument("--log", default=os.path.expanduser(
        "~/Library/Logs/TideSoak/soak.jsonl"), help="watch モードの JSONL 出力先")
    args = ap.parse_args()
    cfg = resolve_config(args)

    def one_round():
        findings, stats = run_pass(cfg, deep=args.deep)
        if findings.count(DRIFT) > 0:
            print(f"  … DRIFT 候補 {findings.count(DRIFT)} 件 → "
                  f"{args.recheck_delay}s 後に再確認（一過性除外）", file=sys.stderr)
            time.sleep(args.recheck_delay)
            second, stats = run_pass(cfg, deep=args.deep)
            findings = findings.merge_persistent(second)
        resources = sample_resources()
        print(format_report(findings, stats, resources))
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
                "drift": findings.count(DRIFT), "warn": findings.count(WARN),
                "info": findings.count(INFO), "stats": stats,
                "resources": resources,
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
    except RuntimeError as e:
        print(f"実行エラー: {e}", file=sys.stderr)
        sys.exit(2)
