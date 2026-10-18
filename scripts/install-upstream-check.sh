#!/usr/bin/env bash
# 安装 / 卸载每日检查上游新版的 launchd 任务（每天 10:00，错过则在下次开机后补跑）。
#   scripts/install-upstream-check.sh            安装或更新
#   scripts/install-upstream-check.sh --remove   卸载
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.tokei.upstream-check"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/.tokei/upstream-check.log"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--remove" ]; then
    rm -f "$PLIST"
    echo "已卸载 $LABEL"
    exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$ROOT/scripts/upstream-check-notify.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "已安装 ${LABEL}：每天 10:00 检查上游，日志 $LOG"
