#!/bin/bash
# soak-watch の launchd 常駐化（Issue #84・標準運用）。
#
# consistency_check.py --fp-only --watch を LaunchAgent（gui ドメイン）で KeepAlive 常駐させ、
# マシン再起動後の「手動再開忘れ = 観測空白」（DB 凍結見張りも止まる）を構造的に防ぐ。
# ターミナル常駐（make soak-watch-fp）は代替/デバッグ用として残る。
#
# サブコマンド:
#   install [interval]  plist を生成して bootstrap（既定 300 秒間隔・再実行 = 再インストール）
#   uninstall           bootout + plist 削除
#   restart             kickstart -k（モード切替ランブックの「watch 再起動」の正規手段）
#   status              実行状態 + 直近の JSONL 1 行
#
# 設計メモ:
# - python3 / aws の実パスと PATH はインストール時に解決して plist へ焼き込む
#   （launchd の既定 PATH に homebrew が無く、aws CLI が見つからないため）。
# - AWS_PROFILE がインストール時のシェルに設定されていればそれも焼き込む
#   （ターミナル運用と同じ資格情報解決を launchd 配下でも再現する）。
# - インストールは既存の watch プロセス（ターミナル常駐）が残っていると中断する —
#   併走すると同じ JSONL に二重追記され soak 実績の集計を汚すため。
set -euo pipefail

LABEL="org.izukawa.tide.soak-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG_DIR="$HOME/Library/Logs/TideSoak"
JSONL="$LOG_DIR/soak.jsonl"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CHECK_SCRIPT="$REPO_ROOT/tools/soak/consistency_check.py"

die() { echo "エラー: $*" >&2; exit 1; }

# launchd 管理外の watch プロセス（ターミナル常駐）を検出する。
# bootout 済みの状態で呼ぶ前提なので、残っていればそれはターミナル側。
terminal_watchers() {
    pgrep -fl "consistency_check.py.*--watch" || true
}

cmd_install() {
    local interval="${1:-300}"
    [[ "$interval" =~ ^[0-9]+$ ]] || die "間隔は秒数で指定してください: $interval"
    # 0/極小は sleep なしで S3 を連打する自傷になるため下限を切る（PR #89 レビュー 3）。
    [ "$interval" -ge 5 ] || die "間隔は 5 秒以上にしてください: $interval"
    [ -f "$CHECK_SCRIPT" ] || die "consistency_check.py が見つかりません: $CHECK_SCRIPT"

    local python3_bin aws_bin
    python3_bin="$(command -v python3)" || die "python3 が見つかりません"
    aws_bin="$(command -v aws)" || die "aws CLI が見つかりません（brew install awscli）"

    # plist へは XML エスケープせず生埋め込みするため、壊す文字を含む値は事前拒否する
    # （PR #89 レビュー 1。発生時に launchctl の分かりにくい失敗ではなく原因を明示する）。
    local v
    for v in "$python3_bin" "$aws_bin" "$CHECK_SCRIPT" "$LOG_DIR" "${AWS_PROFILE:-}"; do
        if [[ "$v" == *['&<>']* ]]; then
            die "XML 特殊文字（& < >）を含む値は plist へ埋め込めません: $v"
        fi
    done

    # 再インストールに備え、先に自分の常駐を外す（未登録なら無視）。
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

    # ターミナル常駐が残っていたら中断（JSONL 二重追記の防止）。bootout は管理下プロセスの
    # 終了完了前に返ることがあるため、少しだけ待って再確認する — 死にかけの自プロセスを
    # ターミナル watch と誤認して中断しない（PR #89 レビュー 2）。
    local watchers try
    for try in 1 2 3; do
        watchers="$(terminal_watchers)"
        [ -z "$watchers" ] && break
        sleep 1
    done
    if [ -n "$watchers" ]; then
        echo "$watchers" >&2
        die "watch プロセスが実行中です。先に停止してください（ターミナルで Ctrl-C）"
    fi

    mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

    # PATH: python3 / aws の各ディレクトリ + 標準パス（defaults 等）。
    local path_env
    path_env="$(dirname "$aws_bin"):$(dirname "$python3_bin"):/usr/bin:/bin:/usr/sbin:/sbin"

    # AWS_PROFILE はインストール時のシェル値を焼き込む（未設定なら省略 = default profile）。
    local profile_xml=""
    if [ -n "${AWS_PROFILE:-}" ]; then
        profile_xml="
        <key>AWS_PROFILE</key><string>$AWS_PROFILE</string>"
    fi

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$python3_bin</string>
        <string>-u</string>
        <string>$CHECK_SCRIPT</string>
        <string>--fp-only</string>
        <string>--watch</string>
        <string>$interval</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$path_env</string>$profile_xml
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>60</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$LOG_DIR/agent.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/agent.err.log</string>
</dict>
</plist>
EOF

    launchctl bootstrap "$DOMAIN" "$PLIST"
    # NB: 全角括弧の直前は必ず ${VAR} でブレースする — macOS の bash 3.2 は「$VAR + 全角文字」を
    # 変数名として誤パースし unbound variable になる。
    echo "インストールしました: ${LABEL}（${interval}s 間隔・--fp-only）"
    echo "  plist   : $PLIST"
    echo "  JSONL   : $JSONL"
    echo "  stdout  : $LOG_DIR/agent.out.log"
    echo "  stderr  : $LOG_DIR/agent.err.log"
    echo "状態確認: make soak-agent-status"
    echo "注意: 初回は「\"python3\" が他のアプリケーションのデータへのアクセスを求めています」の"
    echo "      TCC ダイアログが出るので「許可」する（launchd 配下では python3 が責任プロセスに"
    echo "      なり Group Container 保護に掛かる・拒否すると設定解決が exit 2 で失敗し続ける）。"
}

cmd_uninstall() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "解除しました: ${LABEL}（plist 削除済み）"
}

cmd_restart() {
    [ -f "$PLIST" ] || die "未インストールです（make soak-agent-install）"
    launchctl kickstart -k "$DOMAIN/$LABEL"
    echo "再起動しました: ${LABEL}（スコープ / 凍結見張りの基準を取り直し）"
}

cmd_status() {
    if [ ! -f "$PLIST" ]; then
        # ${PLIST} の波括弧は必須 — 直後の全角「）」を bash が変数名に飲み込み
        # set -u の unbound variable でエラー終了する（bash 3.2 / 5.3 両方で再現）。
        echo "未インストール（plist なし: ${PLIST}）"
        exit 0
    fi
    if ! launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
            | grep -E "state = |pid = |last exit code" | sed 's/^[[:space:]]*/  /'; then
        echo "plist はあるが launchd に未登録です（make soak-agent-install で再登録）"
        exit 0
    fi
    if [ -f "$JSONL" ]; then
        echo "  直近 JSONL: $(tail -1 "$JSONL")"
    else
        echo "  JSONL はまだありません（初回周回待ち）: $JSONL"
    fi
}

case "${1:-}" in
    install)   cmd_install "${2:-}" ;;
    uninstall) cmd_uninstall ;;
    restart)   cmd_restart ;;
    status)    cmd_status ;;
    *)         die "usage: $0 {install [interval]|uninstall|restart|status}" ;;
esac
