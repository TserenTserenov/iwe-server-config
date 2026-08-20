#!/usr/bin/env bash
# PreToolUse:Bash guard — blocks irreversible operations: git (history/staging),
# filesystem (rm -rf outside temp paths), prod DB (psql DROP/TRUNCATE/DELETE
# without WHERE), GitHub repo deletion. Exit 2 = block.
set -euo pipefail

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# Bypass: только из реального шелла пилота (тот же контракт, что secret-leak-block.sh —
# хук читает свой процессный env, не текст команды, агент не может выставить это сам себе).
[ -n "${CC_ALLOW_DESTRUCTIVE_INPUT:-}" ] && exit 0

git_segment() {
  # Return only the shell segment containing `git <global-opts> <subcmd>`.
  # This prevents flags from neighbouring commands (`[ -f file ]`, `rm -f`)
  # from being attributed to `git push`.
  local subcmd="$1"
  SUBCMD="$subcmd" perl -ne '
    my $subcmd = quotemeta($ENV{"SUBCMD"});
    while (/(?:^|[;&|]\s*|\s+)(git(?:\s+(?:-C\s+\S+|--git-dir(?:=|\s+)\S+|--work-tree(?:=|\s+)\S+))*\s+$subcmd\b[^;&|]*)/g) {
      print "$1\n";
      exit 0;
    }
  ' <<< "$CMD"
}

is_git_subcmd() {
  [ -n "$(git_segment "$1")" ]
}

# git push --force / -f (allow the safe --force-with-lease)
PUSH_SEGMENT=$(git_segment push)
if [ -n "$PUSH_SEGMENT" ]; then
  PUSH_FORCE_SCAN=$(echo "$PUSH_SEGMENT" | sed -E 's/--force-with-lease(=[^[:space:]]*)?//g')
  if echo "$PUSH_FORCE_SCAN" | grep -qE -- '(^|[[:space:]])(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --force запрещён. Используй --force-with-lease или согласуй с владельцем (CLAUDE.md §2)."
  fi
fi

# git reset --hard
RESET_SEGMENT=$(git_segment reset)
if [ -n "$RESET_SEGMENT" ] && echo "$RESET_SEGMENT" | grep -qE -- '(^|[[:space:]])--hard([[:space:]]|$)'; then
  block "git reset --hard запрещён (теряет незакоммиченное). Используй git stash."
fi

# git clean with delete flags (-f/-d/-x)
CLEAN_SEGMENT=$(git_segment clean)
if [ -n "$CLEAN_SEGMENT" ] && echo "$CLEAN_SEGMENT" | grep -qE -- '(^|[[:space:]])-[a-zA-Z]*[dfx]'; then
  block "git clean -fdx запрещён (удаляет неотслеживаемые файлы). Согласуй с владельцем."
fi

# git add -A/--all/-u/--update/bare-dot (I7, WP-458: AR.216 жил только в rule-engine.sh
# check_git_staged_only(), которая никогда не диспатчилась ни на одно живое событие —
# реальная защита срабатывала только на commit (install-hooks.sh Check 8), уже после
# стейджа. Здесь — фактический PreToolUse барьер, до того как чужие файлы попадут в индекс.)
ADD_SEGMENT=$(git_segment add)
if [ -n "$ADD_SEGMENT" ]; then
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])(-A|--all|-u|--update)([[:space:]]|$)'; then
    block "git add -A/--all/-u/--update запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])\.([[:space:]]|$)'; then
    block "git add . запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
fi

# rm с одновременным recursive (-r/-R/--recursive) и force (-f/--force), в любом
# сочетании флагов (слитных или раздельных) — вне временных/scratch-путей, где это
# штатная уборка (пир-сессия с Codex, WP-544 Ф1, 20.08).
if echo "$CMD" | grep -qE '(^|[[:space:]])rm([[:space:]]|$)' \
  && echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*[rR][^[:space:]]*|--recursive)([[:space:]]|$)' \
  && echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*f[^[:space:]]*|--force)([[:space:]]|$)' \
  && ! echo "$CMD" | grep -qE '(/tmp/|/scratchpad/|\.claude/worktrees/)'; then
  block "rm -r -f (в любом сочетании флагов) вне /tmp, scratchpad или worktree запрещён — удаление необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DROP/TRUNCATE — необратимая потеря структуры/данных.
if echo "$CMD" | grep -qiE '\bpsql\b' && echo "$CMD" | grep -qiE '\b(DROP[[:space:]]+(TABLE|SCHEMA|DATABASE)|TRUNCATE)\b'; then
  block "DROP/TRUNCATE через psql запрещён — необратимая потеря данных. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DELETE FROM без WHERE в том же операторе (эвристика: сегмент до ближайшего
# ';' или конца строки — не защищает от WHERE в другом statement той же команды).
if echo "$CMD" | grep -qiE '\bpsql\b' \
  && echo "$CMD" | grep -qiE 'DELETE[[:space:]]+FROM' \
  && ! echo "$CMD" | grep -qiE 'DELETE[[:space:]]+FROM[^;]*[[:space:]]WHERE([[:space:]]|$)'; then
  block "DELETE FROM без WHERE через psql запрещён — удалит всю таблицу. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# удаление репозитория на GitHub — необратимо.
if echo "$CMD" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
  block "gh repo delete запрещён — необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

exit 0
