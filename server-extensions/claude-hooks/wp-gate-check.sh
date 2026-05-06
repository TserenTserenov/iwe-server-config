#!/bin/bash
# wp-gate-check.sh — PreToolUse hook на Write/Edit для AR.001 (WP Gate).
# WP-272 Ф2.5 (R23 audit F1): реальная защита от инцидента WP-271.
#
# Срабатывает на попытку Write/Edit `inbox/WP-NNN-*.md` или Edit `WP-REGISTRY.md`.
# Делегирует в rule-engine.sh::check_wp_gate с RULE_EVENT=wp_create_attempt.
#
# user_consent определяется через стейт-файл `.claude/state/wp-consent-${WP_NUM}`,
# который выставляется когда пользователь явно сказал «делаем», «открывай WP-N»,
# «создавай», «начинай» в диалоге (TODO: нужен upstream-механизм для парсинга
# диалога и установки этого файла; пока treated as advisory — block только в
# режиме --strict, иначе warn).
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
if [[ "$FILE_PATH" =~ inbox/WP-([0-9]+)- ]]; then
    WP_NUM="${BASH_REMATCH[1]}"
elif [[ "$FILE_PATH" == *"WP-REGISTRY.md" ]]; then
    WP_NUM="REGISTRY"
else
    exit 0
fi

# Проверка стейт-файла consent (выставляется upstream-парсером диалога)
CONSENT_FILE="$HOME/IWE/.claude/state/wp-consent-${WP_NUM}"
USER_CONSENT="false"
if [ -f "$CONSENT_FILE" ]; then
    USER_CONSENT="true"
fi

# Известные существующие WP — это Edit, не Create. WP context-file уже прошёл
# Ритуал согласования при создании. Skip check для существующих файлов.
if [ -f "$FILE_PATH" ] && [ "$TOOL_NAME" = "Edit" ]; then
    exit 0
fi
if [ -f "$FILE_PATH" ] && [ "$TOOL_NAME" = "Write" ]; then
    # Write по существующему файлу = overwrite, тоже skip (Ритуал прошёл)
    exit 0
fi

# Делегируем в rule-engine
ENGINE="$HOME/IWE/.claude/hooks/rule-engine.sh"
[ ! -x "$ENGINE" ] && exit 0  # rule-engine отсутствует — fail-open

CTX=$(printf '{"file_path":"%s","wp_number":"%s","user_consent":%s,"tool_name":"%s"}' \
    "$FILE_PATH" "$WP_NUM" "$USER_CONSENT" "$TOOL_NAME")

VERDICT=$(RULE_EVENT="wp_create_attempt" RULE_CONTEXT="$CTX" "$ENGINE" dispatch 2>/dev/null)
V=$(echo "$VERDICT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("verdict",""))' 2>/dev/null)

if [ "$V" = "block" ]; then
    REASON=$(echo "$VERDICT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("reason",""))' 2>/dev/null)
    cat >&2 <<EOF
🚫 AR.001 (WP Gate): $REASON

Файл: $FILE_PATH
WP: $WP_NUM

Если пользователь явно согласовал создание этого РП:
  touch $CONSENT_FILE
И повторите Write/Edit. Иначе — пройдите Ритуал согласования (CLAUDE.md §2 п.1).
EOF
    exit 2
fi

exit 0
