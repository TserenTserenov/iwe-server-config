#!/bin/bash
# write-path-post-verify.sh — PostToolUse-хук (Edit|Write|MultiEdit):
# после успешной записи в файл, защищённый манифестом write-path-manifest.yaml,
# перечитывает файл с диска и убеждается, что применённая правка физически
# там — иначе громкий сигнал в stderr + событие write_verify_failed в дневной
# ledger, вместо тихого доверия успеху тула (WP-530 Ф45, консенсус
# Claude+Kimi, пир-сессия MC-sessions:2026-09/17/2026-09-17-11-wp530-peer-finish).
#
# Класс закрываемой дыры (живой инцидент 16.09, WP-530 Ф44): Edit/Write
# вернул успех, но между правками файл переписал кто-то другой (не через
# write-path-lease-guard.sh — событий write_path_bypass не было), откатив уже
# применённые правки. Штатный CAS-механизм (--expected-hash) сработал только
# на СЛЕДУЮЩЕЙ правке, задним числом — само событие потери прошло тихо.
#
# Это PostToolUse, не PreToolUse: он НЕ блокирует и не откатывает уже
# случившуюся запись (это физически невозможно постфактум) — он делает
# потерю видимой сразу после тула, а не в конце сессии через ручной
# git diff --stat.
#
# Область действия (см. также комментарий в write-path-lease-guard.sh и
# WP-530.md Ф45): защищает только путь записи через Claude Code
# Edit/Write/MultiEdit. НЕ обнаруживает и не защищает от записи со стороны
# Kimi headless, Codex, обычных bash-скриптов, раннеров или правки пилота
# напрямую в редакторе — сознательное решение пир-сессии (пилот выбрал
# «простая проверка + честная документация» вместо кросс-рантаймовой
# аренды: и hash-chain, и advisory-lock-конвенция были признаны либо
# недостаточными, либо дающими ложное чувство защищённости). Пункт 2
# карточки Ф44 закрыт этим же решением, не отдельным кодом.
#
# NotebookEdit сознательно не покрыт (в отличие от write-path-lease-guard.sh,
# который его матчит): защищённые манифестом классы — все .md-файлы, ни один
# не редактируется через NotebookEdit; добавлять для него отдельную логику
# сравнения (структура .ipynb — JSON с ячейками, не плоский текст) сейчас
# было бы защитой от несуществующего случая (найдено code review, WP-530 Ф45).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HOOK_DIR/write-path-manifest.yaml"
CHECKER="$HOOK_DIR/write-path-post-verify-check.py"
IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
# Тот же резолвер, что write-path-lease-guard.sh (WP-484 фикс) — иначе
# write_path_bypass (holder с суффиксом сессии) и write_verify_failed (было
# бы голое "claude-code") в дневном ledger не сойдутся по полю agent для
# одной и той же гонки, а именно эта корреляция и нужна при разборе
# (найдено code review, WP-530 Ф45).
IDENTITY_RESOLVER="$IWE_ROOT/$GOV_REPO/scripts/lib/iwe-agent-identity.sh"
AGENT_ID=$(bash "$IDENTITY_RESOLVER" 2>/dev/null) || AGENT_ID="claude-code"

[ -f "$MANIFEST" ] || exit 0
[ -f "$CHECKER" ] || exit 0

INPUT=$(cat)
# Файл, не heredoc: old_string/new_string/content могут содержать что угодно
# (кавычки, переносы, шелл-метасимволы) — небезопасно прогонять через bash-
# переменные; а heredoc, делящий stdin с пайпом JSON в этот же вызов python3,
# сам съедает stdin как текст СВОЕГО СКРИПТА раньше, чем json.load(sys.stdin)
# получит данные (найдено живьём при первой версии этого хука — VERDICT молча
# был "SKIP bad_json" на всех трёх тестовых кейсах).
VERDICT=$(printf '%s' "$INPUT" | python3 "$CHECKER" "$MANIFEST" "$GOV_REPO")
PY_STATUS=$?

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c 'import json,os,sys
try:
    fp = json.load(sys.stdin).get("tool_input", {}).get("file_path", "")
    print(os.path.abspath(os.path.expanduser(fp)) if fp else "")
except Exception:
    pass' 2>/dev/null)

if [ "$PY_STATUS" -ne 0 ]; then
  # Сам чекер упал (не бизнес-логика: FAIL — это штатный, ожидаемый исход) —
  # молчать здесь означало бы нарушить собственный принцип хука «громко, не
  # тихо» на его же отказе (найдено code review, WP-530 Ф45).
  echo "write-path-post-verify: сам чекер упал (exit $PY_STATUS) на '$FILE_PATH' — проверка НЕ выполнена, не значит что правка цела; см. $CHECKER" >&2
  CLASS_ID="checker_error"
  REASON="checker_exit_$PY_STATUS"
else
  case "$VERDICT" in
    SKIP*|OK*|"") exit 0 ;;
  esac
  CLASS_ID=$(printf '%s' "$VERDICT" | awk '{print $2}')
  REASON=$(printf '%s' "$VERDICT" | cut -d' ' -f3-)
  echo "write-path-post-verify: правка '$FILE_PATH' (класс $CLASS_ID) не найдена на диске сразу после записи ($REASON) — не доверяй успеху тула, перечитай файл и разберись, что случилось (см. WP-530 Ф44/Ф45)" >&2
fi

LEDGER="$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh"
if [ -x "$LEDGER" ]; then
  PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({
      "file": sys.argv[1], "class": sys.argv[2], "reason": sys.argv[3],
      "agent": sys.argv[4]}))' \
    "$FILE_PATH" "$CLASS_ID" "$REASON" "$AGENT_ID" 2>/dev/null)
  if [ -n "$PAYLOAD" ]; then
    bash "$LEDGER" day "$(date +%F)" write_verify_failed "$PAYLOAD" \
      write-path-post-verify >/dev/null 2>&1 \
      || echo "TELEMETRY_LOST: write_verify_failed не записан в ledger ($FILE_PATH)" >&2
  fi
fi

exit 0
