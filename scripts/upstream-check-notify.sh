#!/usr/bin/env bash
# 每日定时任务调用：上游发了新版就发一条 macOS 通知，同一个版本只通知一次。只读远端，不合并。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
STATE="$(git rev-parse --git-dir)/tokei-upstream-notified"

output="$("$ROOT/scripts/sync-upstream.sh" --check 2>&1)"
status=$?
echo "$(date '+%F %T') $output"
[ "$status" = 10 ] || exit 0

tag="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
[ "$(cat "$STATE" 2>/dev/null)" = "$tag" ] && exit 0
/usr/bin/osascript -e "display notification \"上游发布了 ${tag}。让 Claude 运行 scripts/sync-upstream.sh 合并，定制会由守护测试把关。\" with title \"Tokei 有新版本\"" \
    && echo "$tag" > "$STATE"
