#!/bin/bash
# wp-gate-check.sh — PreToolUse hook на Write/Edit для AR.001 (WP Gate).
# WP-272 Ф2.5 (R23 audit F1): реальная защита от инцидента WP-271.
# WP-490 (16.07.2026): усилено структурно. Раньше единственной защитой был
# самотач-маркер `.claude/state/wp-consent-{N}`, который создающий РП агент
# может выставить себе сам — и затем вручную Write-нуть context-файл и
# Edit-нуть Registry в обход scripts/create-wp.sh (атомарная запись в 5 мест).
# Живой случай: строка WP-490 прошла в Registry плоским Edit без единого
# замечания хука — «файл существует» пропускало consent-проверку для ЛЮБОГО
# Edit WP-REGISTRY.md, включая вставку совсем новой строки.
#
# Теперь два структурных требования (маркер-файл больше не главный аргумент):
#   1. inbox/WP-N/WP-N.md — Write/MultiEdit НОВОГО (ещё не существующего)
#      context-файла запрещён безусловно. Легитимный путь один —
#      scripts/create-wp.sh (напрямую или через skill /wp-new): он пишет файл
#      Bash-heredoc'ом, что для PreToolUse-хука на Write/Edit невидимо и этим
#      хуком не перехватывается.
#   2. Новая строка в WP-REGISTRY.md (номер, которого в файле раньше не было)
#      разрешена, только если inbox/WP-N/WP-N.md уже существует — ровно тот
#      порядок, который гарантирует create-wp.sh (шаг 1 — context file, шаг 3 —
#      Registry). Строка реестра не может появиться раньше своего context-файла
#      (тот же инвариант уже проверяет commit-hook drift-guard, только post-commit;
#      здесь — та же проверка на edit-time).
#
# Срабатывает на попытку Write/Edit/MultiEdit `inbox/WP-NNN/WP-NNN.md` или
# правку `WP-REGISTRY.md`. Финальный verdict логируется через
# rule-engine.sh::check_wp_gate (AR.001) — тот же журнал/трейс, что и раньше.
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - Exit 0 = allow; exit 2 = block (печатает stderr как block reason).

set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_name", ""))' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); t=d.get("tool_input",{}); print(t.get("file_path", t.get("path", "")))' 2>/dev/null)

# Применимо только к Write/Edit/MultiEdit
case "$TOOL_NAME" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

# Применимо только к WP-context файлам или WP-REGISTRY
WP_NUM=""
IS_REGISTRY=0
if [[ "$FILE_PATH" =~ inbox/WP-([0-9]+)(-|/WP-[0-9]+\.md) ]]; then
    # WP-434: strict — only the WP card (legacy flat WP-N-*.md or canonical WP-N/WP-N.md),
    # not sub-files inside the folder. Consent gate is about creating the РП, not editing notes.
    WP_NUM="${BASH_REMATCH[1]}"
elif [[ "$FILE_PATH" == *"WP-REGISTRY.md" ]]; then
    IS_REGISTRY=1
else
    exit 0
fi

GOV_ROOT="$HOME/IWE/DS-my-strategy"
ENGINE="$HOME/IWE/.claude/hooks/rule-engine.sh"

# Fire-and-forget: логируем block в rule-engine journal (Close-summary/трейс),
# не полагаясь на его verdict — verdict здесь уже структурно решён ниже.
log_block() {
    [ -x "$ENGINE" ] || return 0
    local ctx
    ctx=$(printf '{"file_path":"%s","wp_number":"%s","user_consent":false,"tool_name":"%s"}' \
        "$FILE_PATH" "$1" "$TOOL_NAME")
    RULE_EVENT="wp_create_attempt" RULE_CONTEXT="$ctx" "$ENGINE" dispatch >/dev/null 2>&1
}

# --- Context file, уже существует: обычная правка, Ритуал прошёл при создании ---
if [[ -n "$WP_NUM" && -f "$FILE_PATH" ]]; then
    exit 0
fi

# --- Context file, ещё не существует: создание только через create-wp.sh ---
if [[ -n "$WP_NUM" && ! -f "$FILE_PATH" ]]; then
    log_block "$WP_NUM"
    cat >&2 <<EOF
🚫 AR.001 (WP Gate): создание нового РП напрямую через $TOOL_NAME запрещено.

Файл: $FILE_PATH
WP: $WP_NUM

Context-файл нового РП создаётся ТОЛЬКО через scripts/create-wp.sh (skill /wp-new) —
он атомарно пишет в 5 мест (context, archive stub, Registry, WeekPlan, active-wp).
Прямой Write/MultiEdit этой гарантии не даёт (найдено живьём на WP-490, 16.07.2026).

  touch $HOME/IWE/.claude/state/wp-consent-${WP_NUM}
  bash $HOME/IWE/scripts/create-wp.sh --title "..." --budget Nh --priority PN
EOF
    exit 2
fi

# --- WP-REGISTRY.md: новая строка не может опережать свой context-файл ---
if [[ "$IS_REGISTRY" -eq 1 ]]; then
    NEW_TEXT=$(echo "$INPUT" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
t = d.get("tool_input", {})
parts = []
if "new_string" in t: parts.append(t["new_string"])
if "content" in t: parts.append(t["content"])
for e in (t.get("edits") or []):
    if "new_string" in e: parts.append(e["new_string"])
print("\n".join(parts))
' 2>/dev/null)
    OLD_NUMS=""
    [ -f "$FILE_PATH" ] && OLD_NUMS=$(grep -oE '^\| ~{0,2}[0-9]+' "$FILE_PATH" | grep -oE '[0-9]+' | sort -u)
    NEW_NUMS=$(echo "$NEW_TEXT" | grep -oE '^\| ~{0,2}[0-9]+' | grep -oE '[0-9]+' | sort -u)

    for n in $NEW_NUMS; do
        grep -qx "$n" <<< "$OLD_NUMS" && continue
        [ -f "$GOV_ROOT/inbox/WP-${n}/WP-${n}.md" ] && continue
        log_block "$n"
        cat >&2 <<EOF
🚫 AR.001 (WP Gate): новая строка WP-${n} в WP-REGISTRY.md опережает свой context-файл.

Файл: $FILE_PATH
WP: $n

inbox/WP-${n}/WP-${n}.md ещё не существует — строка Registry не может появиться
раньше него. Реестр правит scripts/create-wp.sh (skill /wp-new): context-файл —
шаг 1, Registry — шаг 3, порядок гарантирован атомарно.
EOF
        exit 2
    done
    exit 0
fi

exit 0
