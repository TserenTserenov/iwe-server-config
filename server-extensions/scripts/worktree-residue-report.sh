#!/bin/bash
# RP-530 F149 (peer-session 2026-10-18-16-dirty-repos-fixes, Claude+Codex):
# session-guard.sh close never cleans up the isolated worktrees it creates --
# live count on 2026-10-18 was 60 in the root repo alone. Codex's objection to
# automating deletion stood: a closed semaphore and age alone do not prove a
# worktree's commits are safely published elsewhere, and this script's own
# first live run found non-prunable worktrees with uncommitted local data
# (see the warning branch below) -- deleting those by age would have lost
# work. This script only reports; it changes nothing on disk. `git worktree
# prune` itself is safe (it only removes bookkeeping for worktrees whose
# directory is already gone) and is NOT wired into session-guard.sh close by
# this patch -- that integration needs its own session against session-guard.sh's
# 51 existing close-path smoke tests, out of scope for this one.
#
# Usage: bash scripts/worktree-residue-report.sh [repo-path ...]
#   No args -> checks $IWE_ROOT (default ~/IWE) and $IWE_ROOT/iwe-local-config,
#   the two repos where worktree growth was observed live.

set -uo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
REPOS=("$@")
[ "${#REPOS[@]}" -eq 0 ] && REPOS=("$IWE_ROOT" "$IWE_ROOT/iwe-local-config")

report_repo() {
    local repo="$1"
    [ -d "$repo/.git" ] || { echo "⚠️  $repo: не git-репозиторий, пропускаю"; return; }

    echo "📁 $repo"
    local repo_toplevel total prunable
    repo_toplevel=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || repo_toplevel="$repo"
    total=$(git -C "$repo" worktree list | wc -l | tr -d ' ')
    prunable=$(git -C "$repo" worktree prune --dry-run -v 2>&1 | grep -c '^Removing worktrees/')
    echo "   всего worktree: $total, годных к очистке git worktree prune: $prunable"
    if [ "$prunable" -gt 0 ]; then
        echo "   кандидаты (директория физически уже удалена, остался только учёт в git):"
        git -C "$repo" worktree prune --dry-run -v 2>&1 | grep '^Removing worktrees/' | sed 's/^/     /'
    fi

    # Worktrees whose directory still exists but whose own semaphore (if any)
    # is closed: real candidates for manual review, not auto-deletion --
    # Codex's objection (unpublished commits, uncommitted data) applies here.
    local line wt_path
    while IFS= read -r line; do
        wt_path=$(printf '%s' "$line" | sed -n 's/^worktree //p')
        [ -n "$wt_path" ] || continue
        [ "$wt_path" = "$repo_toplevel" ] && continue
        # Already covered above as a prune candidate; `git -C` on a missing
        # directory fails, which the diff check below would otherwise
        # misreport as "has uncommitted changes" (it only means "no such dir").
        [ -d "$wt_path" ] || continue
        if ! git -C "$wt_path" diff --quiet 2>/dev/null || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
            echo "   ⚠️  $wt_path: есть незакоммиченные изменения — не трогать без ручной проверки"
        fi
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    echo ""
}

for repo in "${REPOS[@]}"; do
    report_repo "$repo"
done

echo "Это только отчёт. Чтобы убрать учёт действительно удалённых директорий (безопасная операция): git worktree prune"
echo "Директории с найденным незакоммиченным — решение пилота, не автоматика."
