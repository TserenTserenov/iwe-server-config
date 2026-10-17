#!/usr/bin/env bash
# wp-card-license-gate.sh -- PreToolUse гейт лицензии на правку карточки РП
# (WP-484 Ф210, 17.10.2026, пир-сессия Kimi+Codex+Grok, consensus reached).
#
# Повод: open --isolate не форсировал wp-reopen-gate actualize, и первая
# правка карточки могла пойти по устаревшей копии без лицензии (плановый
# слой а — авто-actualize внутри open --isolate — закрывает штатный путь;
# этот хук закрывает остальные пути к карточке).
#
# Границы (зафиксированы consensus'ом, не расширять молча):
#   - Скоуп v1 УЗКИЙ: только Edit/Write/MultiEdit файла inbox/WP-NNN/WP-NNN.md
#     из сессии, семафор которой несёт isolated_worktree. Правка кода до
#     actualize и запись карточки через shell НЕ покрыты — сознательное
#     ограничение v1, оговорка сохраняется в отчёте пилоту. Инвариант
#     «любая правка карточки» шире Ф210 и выносится отдельной задачей.
#   - Граница отказов: fail-open ТОЛЬКО когда вход не собран (файл/сессия/WP/
#     флаг изоляции не определены, или семафор неоднозначен — неоднозначность
#     не доказательство отсутствия сессии). Сессия ОПРЕДЕЛЕНА, а check-edit
#     дал что угодно, кроме подтверждённого допуска (exit 2, обрыв, таймаут,
#     exit вне {0,2}) → deny с диагностикой: поломка проверки не должна
#     становиться обходом. Read, диагностика и сам actualize доступны всегда.
#
# Контракт PreToolUse hook (Claude Code): stdin JSON {tool_name, session_id,
# tool_input, ...}; JSON {"hookSpecificOutput": {..., "permissionDecision":
# "deny", ...}} на stdout блокирует; пустой вывод (exit 0) разрешает.

set -uo pipefail
export PATH="/run/current-system/sw/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0  # вход не собран -- fail-open

# Только карточка РП в inbox/ (где угодно в дереве — копия может быть
# изолированным worktree, не только канон).
WP_NUM=$(printf '%s' "$FILE_PATH" | sed -nE 's:.*/inbox/WP-([0-9]+)/WP-[0-9]+\.md$:\1:p')
[ -n "$WP_NUM" ] || exit 0  # не карточка inbox -- вне скоупа v1

HOOK_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
AGENT="${IWE_AGENT:-claude-code}"
HARNESS_ID="${HARNESS_SESSION_ID:-$HOOK_SESSION_ID}"
[ -n "$HARNESS_ID" ] || exit 0  # вход не собран -- fail-open

# Ровно один семафор этой сессии (тот же контракт, что у
# post-tool-use-scope-track.sh, WP-484 Ф101): ни одного или больше одного —
# не угадываем, fail-open.
SEM_MATCHES=$(grep -lF "harness_session_id: $HARNESS_ID" "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null)
SEM_COUNT=$(printf '%s\n' "$SEM_MATCHES" | grep -c . || true)
[ "$SEM_COUNT" -eq 1 ] || exit 0
SEM_FILE="$SEM_MATCHES"

# Предикат изоляции: гейт работает только для isolated-сессий (честный
# узкий скоуп Ф210). Сессия без isolated_worktree -- вне области действия.
grep -qE '^isolated_worktree: .+' "$SEM_FILE" 2>/dev/null || exit 0

GUARD_SESSION_ID=$(sed -n 's/^session_id: //p' "$SEM_FILE" 2>/dev/null | head -1)
GOV_WT=$(sed -n 's/^governance_worktree: //p' "$SEM_FILE" 2>/dev/null | head -1)
[[ "$GUARD_SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] || exit 0
[ -n "$GOV_WT" ] || exit 0

GATE="$IWE_ROOT/scripts/wp-reopen-gate.sh"
[ -x "$GATE" ] || exit 0  # гейт недоступен -- не блокируем (protective fallback)

# Любой исход, кроме подтверждённого editing_allowed (exit 0), -- deny:
# exit 2 (нет лицензии/чужая сессия/TTL/digest разошёлся), обрыв, таймаут,
# exit вне {0,2} (consensus Codex+Grok, ход 2/3).
if "$GATE" check-edit --wp "$WP_NUM" --governance-repo "$GOV_WT" \
     --session-id "$GUARD_SESSION_ID" >/dev/null 2>&1; then
  exit 0
fi

jq -n \
  --arg wp "$WP_NUM" \
  --arg wt "$GOV_WT" \
  --arg sid "$GUARD_SESSION_ID" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("WP-484 Ф210: правка карточки WP-" + $wp + " без валидной лицензии wp-reopen-gate (check-edit не дал editing_allowed). Выполни: wp-reopen-gate.sh actualize --wp " + $wp + " --governance-repo " + $wt + " --session-id " + $sid + " — затем повтори правку. Если actualize отказывает из-за расхождения карточки с origin — согласуй порядок правок с пилотом, файл не изменён.")
    }
  }'
exit 0
