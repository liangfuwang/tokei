#!/usr/bin/env bash
# 把上游 cclank/tokei 的新版本合并进本 fork，同时守住本地定制（见 docs/local-customizations.md）。
#
# 用法：
#   scripts/sync-upstream.sh --check        只检查上游有没有 main 还没合并的新版本（退出码 10 = 有新版）
#   scripts/sync-upstream.sh [<ref>]        在新分支 sync/<ref> 上合并（默认最新的上游版本 tag），
#                                           跑定制守护测试和全套测试，再打本地包
#   scripts/sync-upstream.sh --verify       解决完冲突、提交后，在当前分支上补跑测试和打包
#
# 选项：--no-build 不打包；--quick 只跑定制守护测试，不跑全套测试。
# 只在本地操作：不推送、不安装、不动 main。确认无误后再自己把 sync 分支合进 main。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
UPSTREAM="${TOKEI_UPSTREAM_REMOTE:-origin}"
MODE="sync"; TARGET=""; BUILD=1; FULL=1
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --verify) MODE="verify" ;;
        --no-build) BUILD=0 ;;
        --quick) FULL=0 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        -*) echo "未知选项：$arg" >&2; exit 1 ;;
        *) TARGET="$arg" ;;
    esac
done

log() { printf '\n==> %s\n' "$*"; }

latest_upstream_tag() {
    git tag -l 'v[0-9]*' --sort=-v:refname | head -1
}

fetch_upstream() {
    git fetch --quiet --tags "$UPSTREAM"
}

failures() {  # 从 unittest 输出里取失败用例名
    grep -E '^(FAIL|ERROR): ' "$1" | sort -u || true
}

run_tests() {
    log "定制守护测试（必须全过）"
    if ! python3 -m unittest discover -s tests -p 'test_local_customizations.py'; then
        echo "定制守护测试失败：有定制在合并中丢失或失效，先修好再继续。" >&2
        exit 3
    fi
    python3 -m py_compile usage.30s.py
    [ "$FULL" = 1 ] || return 0

    log "全套测试（与合并前对比，只看新增失败）"
    local tmp base_wt new_log base_log
    tmp="$(mktemp -d)"; new_log="$tmp/new.log"; base_log="$tmp/base.log"
    base_wt="$tmp/base"
    local base="${BASE_COMMIT:-}"
    if [ -n "$base" ]; then
        git worktree add --quiet --detach "$base_wt" "$base"
        # 先后跑，不能并行：两套测试同时跑会争用共享的临时状态，出现假失败
        ( cd "$base_wt" && python3 -m unittest discover -s tests >"$base_log" 2>&1 || true )
    fi
    python3 -m unittest discover -s tests >"$new_log" 2>&1 || true
    tail -3 "$new_log"
    if [ -n "$base" ]; then
        local added
        added="$(comm -13 <(failures "$base_log") <(failures "$new_log"))"
        git worktree remove --force "$base_wt"
        if [ -n "$added" ]; then
            echo "合并后新增的失败用例："; echo "$added"
            echo "完整输出：$new_log" >&2
            exit 4
        fi
        echo "没有新增失败（合并前就失败的用例：$(failures "$base_log" | wc -l | tr -d ' ') 个）。"
    else
        failures "$new_log"
    fi
}

build_app() {
    [ "$BUILD" = 1 ] || return 0
    log "打本地包（不安装）"
    ( cd Tokei && TOKEI_LOCAL_BUILD=1 TOKEI_ARCHS="${TOKEI_ARCHS:-arm64}" ./package.sh >/dev/null )
    echo "产物：$ROOT/Tokei/Tokei.app、$ROOT/Tokei/Tokei.dmg"
}

case "$MODE" in
check)
    fetch_upstream
    tag="$(latest_upstream_tag)"
    if [ -z "$tag" ]; then echo "上游没有版本 tag"; exit 1; fi
    if git merge-base --is-ancestor "$tag" main; then
        echo "已包含上游最新版本 $tag"
        exit 0
    fi
    echo "上游有新版本：${tag}（main 尚未合并）"
    exit 10
    ;;
verify)
    if [ -n "$(git status --porcelain --untracked-files=no)" ] || git ls-files -u | grep -q .; then
        echo "工作区还有未提交或未解决的改动，先解决冲突并提交。" >&2
        exit 1
    fi
    BASE_COMMIT="$(git rev-parse HEAD^1 2>/dev/null || true)"
    run_tests
    build_app
    log "完成。确认无误后：git checkout main && git merge --ff-only $(git rev-parse --abbrev-ref HEAD)"
    ;;
sync)
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        echo "工作区有未提交的改动，先提交或暂存。" >&2
        exit 1
    fi
    fetch_upstream
    TARGET="${TARGET:-$(latest_upstream_tag)}"
    git rev-parse --verify --quiet "$TARGET^{commit}" >/dev/null || { echo "找不到 $TARGET" >&2; exit 1; }
    if git merge-base --is-ancestor "$TARGET" HEAD; then
        echo "已包含 ${TARGET}，无需同步。"
        exit 0
    fi
    BASE_COMMIT="$(git rev-parse HEAD)"
    branch="sync/${TARGET#"$UPSTREAM"/}"
    if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        echo "分支 $branch 已存在；继续它就 git checkout ${branch}，重来就先删掉它。" >&2
        exit 1
    fi

    log "预演合并 $TARGET"
    conflicts="$(git merge-tree --write-tree --name-only HEAD "$TARGET" | sed -n '2,/^$/p' | sed '/^$/d' || true)"
    if [ -n "$conflicts" ]; then echo "会冲突的文件："; echo "$conflicts"; else echo "无冲突"; fi

    log "在分支 $branch 上合并"
    git checkout --quiet -b "$branch"
    if ! git merge --no-ff --no-edit -m "merge upstream $TARGET" "$TARGET"; then
        echo
        echo "有冲突，已停在分支 ${branch}。解决冲突时保住本地定制（对照 docs/local-customizations.md），然后："
        echo "  git add <文件> && git commit --no-edit && scripts/sync-upstream.sh --verify"
        exit 2
    fi
    run_tests
    build_app
    log "完成。确认无误后：git checkout main && git merge --ff-only $branch"
    ;;
esac
