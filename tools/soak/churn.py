#!/usr/bin/env python3
"""Tide soak 負荷注入（churn）スクリプト（Issue #40 の 1 台加速 soak 用）。

FSEvents 側同期フォルダと File Provider 側レプリカ（~/Library/CloudStorage/Tide-Tide）の
両方へ create / edit / rename / move / delete / mkdir / dir move / read（FP materialize 誘発）を
乱数注入し、「アプリ = 書き手」×「FP 拡張 = 第 3 の書き手」の交錯を 1 台で作る。
consistency_check.py の常時観測（--watch）と併走させる前提。

安全ガード（実データを壊さない）:
- 書込は専用サブツリー（既定 soak-churn-app / soak-churn-fp / soak-churn-shared）内のみ。
  起動時に realpath がルート配下であることを検証し、操作対象はスクリプトが作った
  パスの台帳（ledger）に限定する。symlink は作らず追わない。
- --max-files / --max-total-mb で生成量を有界化。dotfile・`.syncignore` 名は生成しない
  （ignore 系の意図せぬ発火を防ぐ。`.syncignore` シナリオは手動チェックリスト側で行う）。

再現性: --seed 固定の乱数 + 全操作を JSONL（--log）へ記録（seed + ログで完全再現可能）。

kill 注入: --kill-app-every / --kill-ext-every。マルチパート生成（--multipart-every）の
直後は転送中を狙って kill を優先スケジュールする。
ネット断（--net-blip-every）は opt-in（既定 OFF・Wi-Fi を実際に落とすので副作用に注意）。
スリープ復帰は自動化しない（復帰スケジュールに sudo が要り、スリープ中は本スクリプトも
止まる）— 手動チェックリスト側で行う。

終了コード: 0 = 正常終了（--duration-min 満了 or --ops 消化）/ 130 = Ctrl-C / 2 = 実行エラー。
"""

import argparse
import datetime
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time

GROUP_CONTAINER = os.path.expanduser(
    "~/Library/Group Containers/G5G54TCH8W.org.izukawa.Tide"
)
GROUP_PLIST = os.path.join(
    GROUP_CONTAINER, "Library/Preferences/G5G54TCH8W.org.izukawa.Tide"
)
DEFAULT_FP_ROOT = os.path.expanduser("~/Library/CloudStorage/Tide-Tide")
DEFAULT_APP_PATH = "build/Build/Products/Debug/Tide.app"

# 操作ミックス（重み）。read は FP 側のみ（dataless → materialize 誘発）。
OP_WEIGHTS = [
    ("create", 30),
    ("edit", 25),
    ("delete", 15),
    ("rename", 10),
    ("move", 10),
    ("mkdir", 5),
    ("dir_move", 5),   # #67 実地回帰（dir move = 全削除 + 全追加として伝播）
    ("read", 5),       # FP 側のみ意味を持つ（app 側に当たったら create に読み替え）
]


def config_error(message):
    print(f"設定エラー: {message}", file=sys.stderr)
    sys.exit(2)


def defaults_read(key):
    """group defaults から 1 キー読む。未設定なら None（consistency_check.py と同一規約）。"""
    try:
        out = subprocess.run(
            ["defaults", "read", GROUP_PLIST, key],
            capture_output=True, text=True, encoding="utf-8", timeout=10,
        )
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


# ---------------------------------------------------------------- 対象ツリー

class Side:
    """1 書込サイド（app / fp / 共有×2）。スクリプトが作ったパスだけを台帳で管理する。"""

    def __init__(self, label, root, subtree):
        self.label = label            # ログ用: "app" / "fp" / "shared@app" / "shared@fp"
        self.root = root              # 同期ルート（syncRoot or FP レプリカ）
        self.subtree = subtree        # ルートからの相対サブツリー名
        self.base = os.path.join(root, subtree)
        self.files = []               # 台帳: base からの相対パス（ファイル）
        self.dirs = [""]              # 台帳: base からの相対パス（ディレクトリ。"" = base 直下）
        self.live_bytes = 0

    def validate(self):
        real_root = os.path.realpath(self.root)
        real_base = os.path.realpath(self.base) if os.path.exists(self.base) \
            else os.path.realpath(os.path.dirname(self.base) or ".")
        if not os.path.isdir(self.root):
            config_error(f"{self.label}: ルートが存在しません: {self.root}")
        if os.path.islink(self.base):
            config_error(f"{self.label}: サブツリーが symlink です: {self.base}")
        if real_base != real_root and not real_base.startswith(real_root + os.sep):
            config_error(f"{self.label}: サブツリーがルート外を指しています: {self.base}")

    def abs_file(self, rel):
        return os.path.join(self.base, rel)


# ---------------------------------------------------------------- churn 本体

class Churn:
    def __init__(self, args, sides, rng, log_path):
        self.args = args
        self.sides = sides
        self.rng = rng
        self.log_path = log_path
        self.op_index = 0
        self.counters = {}            # op 名 -> 実行数
        self.errors = 0
        self.pending_kills = []       # マルチパート直後の優先 kill（"app"/"ext"）
        self.name_seq = 0

    # ---- 生成名（dotfile / .syncignore を絶対に作らない） ----

    def new_name(self, ext=".dat"):
        self.name_seq += 1
        return f"f{self.name_seq:05d}-{self.rng.randrange(16**4):04x}{ext}"

    def new_dirname(self):
        self.name_seq += 1
        return f"d{self.name_seq:05d}"

    # ---- 台帳ヘルパ ----

    def total_files(self):
        # 共有サブツリーは 2 サイドが台帳を共有（エイリアス）するので id で重複排除する。
        seen = {id(s.files): len(s.files) for s in self.sides}
        return sum(seen.values())

    def total_mb(self):
        return sum(s.live_bytes for s in self.sides) / (1024 * 1024)

    def prune_missing(self, side, rel):
        """ENOENT の台帳整理。専用サブツリー（app/fp）は外的消失 = 台帳から除去。
        共有サブツリーは「他サイドの書込がこの root へ未伝播」が主因なので**保持**して後で再試行する
        （除去すると伝播後のファイルが誰にも触られない残骸として無限に積み上がる）。"""
        if side.label in ("app", "fp") and rel in side.files:
            side.files.remove(rel)

    # ---- 個別操作（すべて base 配下の台帳パスのみを触る） ----

    def op_create(self, side, size=None):
        if size is None:
            size = self.rng.randrange(1024, 256 * 1024)
        if self.total_files() >= self.args.max_files or \
           self.total_mb() + size / (1024 * 1024) > self.args.max_total_mb:
            # 上限到達時は「一番ファイルを抱えるサイド」からの削除へ振り替えて定常状態を保つ
            # （空サイドへの delete → create の相互再帰を避ける）。
            victim = max(self.sides, key=lambda s: len(s.files))
            if victim.files:
                return self.op_delete(victim)
            return {"op": "noop", "path": "", "reason": "caps"}
        parent = self.rng.choice(side.dirs)
        rel = os.path.join(parent, self.new_name())
        full = side.abs_file(rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(self.rng.randbytes(size))
        side.files.append(rel)
        side.live_bytes += size
        return {"op": "create", "path": rel, "bytes": size}

    def op_edit(self, side):
        if not side.files:
            return self.op_create(side)
        rel = self.rng.choice(side.files)
        full = side.abs_file(rel)
        size = self.rng.randrange(1024, 128 * 1024)
        mode = self.rng.choice(["overwrite", "append"])
        try:
            with open(full, "wb" if mode == "overwrite" else "ab") as f:
                f.write(self.rng.randbytes(size))
        except FileNotFoundError:
            self.prune_missing(side, rel)
            return {"op": "edit", "path": rel, "stale": True}
        side.live_bytes += size  # 概算（overwrite の旧サイズ分は無視 = 安全側の過大見積り）
        return {"op": "edit", "path": rel, "bytes": size, "mode": mode}

    def op_delete(self, side):
        if not side.files:
            return self.op_create(side)
        rel = self.rng.choice(side.files)
        try:
            os.remove(side.abs_file(rel))
        except FileNotFoundError:
            self.prune_missing(side, rel)
            return {"op": "delete", "path": rel, "stale": True}
        side.files.remove(rel)
        # 「編集 → 削除 → 復元」の反復: 一定確率で同 path をすぐ再作成（削除伝播と作成の交錯）。
        recreated = False
        if self.rng.random() < 0.3:
            time.sleep(self.rng.uniform(0.2, 2.0))
            size = self.rng.randrange(1024, 64 * 1024)
            with open(side.abs_file(rel), "wb") as f:
                f.write(self.rng.randbytes(size))
            side.files.append(rel)
            recreated = True
        return {"op": "delete", "path": rel, "recreated": recreated}

    def op_rename(self, side):
        if not side.files:
            return self.op_create(side)
        rel = self.rng.choice(side.files)
        new_rel = os.path.join(os.path.dirname(rel), self.new_name())
        try:
            os.rename(side.abs_file(rel), side.abs_file(new_rel))
        except FileNotFoundError:
            self.prune_missing(side, rel)
            return {"op": "rename", "path": rel, "stale": True}
        side.files.remove(rel)
        side.files.append(new_rel)
        return {"op": "rename", "path": rel, "dst": new_rel}

    def op_move(self, side):
        if not side.files or len(side.dirs) < 2:
            return self.op_mkdir(side)
        rel = self.rng.choice(side.files)
        dst_dir = self.rng.choice([d for d in side.dirs if d != os.path.dirname(rel)] or side.dirs)
        new_rel = os.path.join(dst_dir, os.path.basename(rel))
        if new_rel == rel or new_rel in side.files:
            return self.op_rename(side)
        try:
            os.rename(side.abs_file(rel), side.abs_file(new_rel))
        except FileNotFoundError:
            self.prune_missing(side, rel)
            return {"op": "move", "path": rel, "stale": True}
        side.files.remove(rel)
        side.files.append(new_rel)
        return {"op": "move", "path": rel, "dst": new_rel}

    def op_mkdir(self, side):
        parent = self.rng.choice(side.dirs)
        rel = os.path.join(parent, self.new_dirname())
        os.makedirs(side.abs_file(rel), exist_ok=True)
        side.dirs.append(rel)
        return {"op": "mkdir", "path": rel}

    def op_dir_move(self, side):
        movable = [d for d in side.dirs if d and any(f.startswith(d + os.sep) for f in side.files)]
        if not movable:
            return self.op_mkdir(side)
        src = self.rng.choice(movable)
        dst = os.path.join(os.path.dirname(src), self.new_dirname())
        try:
            os.rename(side.abs_file(src), side.abs_file(dst))
        except FileNotFoundError:
            return {"op": "dir_move", "path": src, "stale": True}
        # 台帳の付け替え（src 配下すべて）
        side.dirs = [dst if d == src else
                     (dst + d[len(src):] if d.startswith(src + os.sep) else d)
                     for d in side.dirs]
        side.files = [dst + f[len(src):] if f.startswith(src + os.sep) else f
                      for f in side.files]
        return {"op": "dir_move", "path": src, "dst": dst}

    def op_read(self, side):
        """FP 側: dataless の可能性があるファイルを読んで materialize を誘発する。"""
        if side.label.endswith("app") or not side.files:
            return self.op_create(side)
        rel = self.rng.choice(side.files)
        n = 0
        try:
            with open(side.abs_file(rel), "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    n += len(chunk)
        except FileNotFoundError:
            self.prune_missing(side, rel)
            return {"op": "read", "path": rel, "stale": True}
        return {"op": "read", "path": rel, "bytes": n}

    # ---- kill / net 注入 ----

    def inject_kill(self, target):
        if target == "app":
            subprocess.run(["pkill", "-x", "Tide"], capture_output=True)
            time.sleep(self.rng.uniform(2, 5))
            subprocess.run(["open", self.args.app_path], capture_output=True)
            return {"op": "kill_app", "path": self.args.app_path}
        subprocess.run(["pkill", "-f", "TideFileProvider.appex"], capture_output=True)
        return {"op": "kill_ext", "path": "(fileproviderd がオンデマンド再起動)"}

    def inject_net_blip(self):
        dev = self.args.wifi_device
        subprocess.run(["networksetup", "-setairportpower", dev, "off"], capture_output=True)
        off_sec = self.rng.uniform(30, 120)
        time.sleep(off_sec)
        subprocess.run(["networksetup", "-setairportpower", dev, "on"], capture_output=True)
        return {"op": "net_blip", "path": dev, "off_sec": round(off_sec)}

    # ---- 1 op 実行 + JSONL 記録 ----

    def log(self, side_label, record, ok, error=None):
        entry = {
            "ts": datetime.datetime.now().isoformat(timespec="seconds"),
            "seed": self.args.seed, "op_index": self.op_index,
            "side": side_label, "ok": ok, **record,
        }
        if error:
            entry["error"] = str(error)[:300]
        with open(self.log_path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def run_one(self):
        self.op_index += 1

        # マルチパート直後の優先 kill（転送中を狙う）
        if self.pending_kills:
            target = self.pending_kills.pop(0)
            rec = self.inject_kill(target)
            self.counters[rec["op"]] = self.counters.get(rec["op"], 0) + 1
            self.log("-", rec, True)
            return

        # 定期注入（kill / net）
        for every, target in [(self.args.kill_app_every, "app"),
                              (self.args.kill_ext_every, "ext")]:
            if every and self.op_index % every == 0:
                rec = self.inject_kill(target)
                self.counters[rec["op"]] = self.counters.get(rec["op"], 0) + 1
                self.log("-", rec, True)
                return
        if self.args.net_blip_every and self.op_index % self.args.net_blip_every == 0:
            rec = self.inject_net_blip()
            self.counters[rec["op"]] = self.counters.get(rec["op"], 0) + 1
            self.log("-", rec, True)
            return

        side = self.rng.choice(self.sides)

        # マルチパート閾値（16 MiB）超の大物を定期投入 → 直後スロットに kill を優先予約
        if self.args.multipart_every and self.op_index % self.args.multipart_every == 0:
            try:
                rec = self.op_create(side, size=20 * 1024 * 1024)
                if rec["op"] == "create":   # 上限到達で delete へ振り替わった場合は素の記録のまま
                    rec["multipart"] = True
                    self.counters["multipart"] = self.counters.get("multipart", 0) + 1
                self.log(side.label, rec, True)
            except OSError as e:
                self.errors += 1
                self.log(side.label, {"op": "create", "multipart": True}, False, e)
            if self.args.kill_app_every:
                self.pending_kills.append("app")
            elif self.args.kill_ext_every:
                self.pending_kills.append("ext")
            return

        name = self.rng.choices([n for n, _ in OP_WEIGHTS],
                                weights=[w for _, w in OP_WEIGHTS])[0]
        try:
            rec = getattr(self, f"op_{name}")(side)
            self.counters[rec["op"]] = self.counters.get(rec["op"], 0) + 1
            self.log(side.label, rec, True)
        except OSError as e:
            # FP 側は fileproviderd の一時拒否等で失敗し得る（記録して続行 = soak の観測対象）
            self.errors += 1
            self.counters["error"] = self.counters.get("error", 0) + 1
            self.log(side.label, {"op": name}, False, e)


# ---------------------------------------------------------------- main

def positive_or_none(v):
    n = int(v)
    return n if n > 0 else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sync-root", help="FSEvents 側同期フォルダ（省略時 group defaults）")
    ap.add_argument("--fp-root", default=DEFAULT_FP_ROOT,
                    help=f"FP レプリカのルート（既定 {DEFAULT_FP_ROOT}）")
    ap.add_argument("--subtree", default="soak-churn",
                    help="専用サブツリー名の接頭辞（既定 soak-churn → soak-churn-app 等）")
    ap.add_argument("--seed", type=int, default=40, help="乱数シード（既定 40）")
    ap.add_argument("--ops", type=int, default=0, help="総 op 数（0 = 無制限・Ctrl-C まで）")
    ap.add_argument("--duration-min", type=int, default=0, help="実行時間（分・0 = 無制限）")
    ap.add_argument("--interval-ms", default="500-5000",
                    help="op 間隔のジッタ範囲 ms（既定 500-5000）")
    ap.add_argument("--burst", type=int, default=4,
                    help="確率 1/8 で連続注入する op 数（debounce 2 秒との交錯・既定 4）")
    ap.add_argument("--active-min", type=int, default=50,
                    help="duty cycle の活動分（既定 50。静穏窓で consistency_check の判定を確定させる）")
    ap.add_argument("--quiesce-min", type=int, default=10, help="duty cycle の静穏分（既定 10）")
    ap.add_argument("--max-files", type=int, default=500, help="生成ファイル数上限（既定 500）")
    ap.add_argument("--max-total-mb", type=int, default=512, help="生成総量上限 MB（既定 512）")
    ap.add_argument("--multipart-every", type=positive_or_none, default=200,
                    help="N op ごとに 20MB（16 MiB 閾値超 = マルチパート）を投入（既定 200・0 で無効）")
    ap.add_argument("--kill-app-every", type=positive_or_none, default=0,
                    help="N op ごとに Tide.app を kill → 再起動（既定 0 = 無効）")
    ap.add_argument("--kill-ext-every", type=positive_or_none, default=0,
                    help="N op ごとに FP 拡張を kill（fileproviderd が再起動・既定 0 = 無効）")
    ap.add_argument("--net-blip-every", type=positive_or_none, default=0,
                    help="N op ごとに Wi-Fi を 30〜120 秒 OFF → ON（opt-in・既定 0 = 無効）")
    ap.add_argument("--wifi-device", default="en0", help="--net-blip の対象デバイス（既定 en0）")
    ap.add_argument("--app-path", default=DEFAULT_APP_PATH,
                    help=f"kill 後に再起動する .app（既定 {DEFAULT_APP_PATH}）")
    ap.add_argument("--no-cross-write", action="store_true",
                    help="共有サブツリー（両サイドが同一相対パスへ書く = 競合誘発）を無効化")
    ap.add_argument("--dry-run", action="store_true", help="対象と設定を表示して終了")
    ap.add_argument("--log", default=os.path.expanduser(
        "~/Library/Logs/TideSoak/churn.jsonl"), help="操作ログ JSONL の出力先")
    args = ap.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.subtree):
        config_error(f"--subtree が不正です（英数字始まり・[A-Za-z0-9._-] のみ）: {args.subtree}")
    m = re.fullmatch(r"(\d+)-(\d+)", args.interval_ms)
    if not m or int(m.group(1)) > int(m.group(2)):
        config_error(f"--interval-ms は 'MIN-MAX' 形式で指定してください: {args.interval_ms}")
    interval = (int(m.group(1)) / 1000, int(m.group(2)) / 1000)

    sync_root = args.sync_root or defaults_read("tide.syncRootPath")
    if not sync_root:
        config_error("同期フォルダを解決できません（group defaults 未設定 or --sync-root 不足）")

    sides = [Side("app", sync_root, f"{args.subtree}-app"),
             Side("fp", args.fp_root, f"{args.subtree}-fp")]
    if not args.no_cross_write:
        # 同一相対パスのサブツリーへ両サイドが書く = 3-way 競合・uploadConflict・
        # .conflictThenDownload を意図的に発火させる（1 台交錯 soak の主目的）。
        # **台帳（files/dirs）は 2 サイドで共有（エイリアス）**: 一方が作ったパスをもう一方が
        # 編集/削除/リネームすることで、同一相対パスへの交錯書込が実際に起きる。
        # 未伝播パスへの操作は ENOENT → stale 記録（台帳保持）→ 伝播後に再試行される。
        shared_app = Side("shared@app", sync_root, f"{args.subtree}-shared")
        shared_fp = Side("shared@fp", args.fp_root, f"{args.subtree}-shared")
        shared_fp.files = shared_app.files
        shared_fp.dirs = shared_app.dirs
        sides += [shared_app, shared_fp]
    for side in sides:
        side.validate()

    rng = random.Random(args.seed)
    os.makedirs(os.path.dirname(args.log), exist_ok=True)

    print(f"churn: seed={args.seed} sides={[s.label for s in sides]}")
    for side in sides:
        print(f"  {side.label}: {side.base}")
    print(f"  max: {args.max_files} files / {args.max_total_mb} MB / "
          f"multipart every {args.multipart_every} / duty {args.active_min}+{args.quiesce_min}min")
    print(f"  log: {args.log}")
    if args.dry_run:
        return

    for side in sides:
        os.makedirs(side.base, exist_ok=True)

    churn = Churn(args, sides, rng, args.log)
    started = time.time()
    cycle = (args.active_min + args.quiesce_min) * 60

    while True:
        if args.ops and churn.op_index >= args.ops:
            break
        if args.duration_min and (time.time() - started) > args.duration_min * 60:
            break
        # duty cycle: 各サイクルの後半 quiesce-min は完全静穏（DRIFT 判定の確定窓）
        if args.quiesce_min:
            pos = (time.time() - started) % cycle
            if pos >= args.active_min * 60:
                time.sleep(cycle - pos + 1)
                continue
        burst = rng.randrange(1, args.burst + 1) if rng.random() < 0.125 else 1
        for _ in range(burst):
            churn.run_one()
        time.sleep(rng.uniform(*interval))

    print(f"churn 終了: {churn.op_index} ops / errors {churn.errors}")
    for name in sorted(churn.counters):
        print(f"  {name}: {churn.counters[name]}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as e:
        print(f"実行エラー: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
