#!/usr/bin/env bash
# session-handoff-gate.sh -- hard pre-action gate for protocol-open.md
# §Сессия шаг 3.6 (РП-484 Ф197, 16.10.2026, прямое поручение пилота —
# "я хочу реализацию запрета, потому что это очень важно").
#
# Повод: шаг 3.6 (цитировать/прочитать report.md последней сессии РП перед
# Ритуалом) был чисто текстовой инструкцией, и живой пример (сессия по
# РП-560) показал, что текст не держит — Ритуал объявили по устаревшей
# строке реестра, не прочитав готовый отчёт предыдущей сессии (найдено
# пилотом, см. WP-484 Ф194 "Доп. находка того же дня").
#
# Scope (узко, по образцу ritual-hard-gate.sh, та же пилотская философия
# "зеро-неоднозначный сигнал, не судить за агента"):
#   - Применяется ТОЛЬКО к Write/Edit/MultiEdit (не к Bash/Read) -- блок
#     содержательной правки, не диагностики/бухгалтерии сессии. Блокировать
#     Bash тоже означало бы ломать легитимную до-ритуальную бухгалтерию
#     (session-guard.sh open, чтение WP-REGISTRY и т.п.), для которой ещё
#     не спроектирован allowlist -- тот же компромисс, которым объясняет
#     свою узость сам ritual-hard-gate.sh.
#   - Срабатывает ТОЛЬКО когда ПОСЛЕДНЕЕ сообщение пилота явно называет
#     WP-NNN/РП-NNN -- та же узость, тот же resolved-номер, что и
#     ritual_prompt_names_wp (зачем дублировать: см. ritual-detect.sh).
#   - Сканер (wp-session-journal-gaps.py) запускается этим ХУКОМ напрямую,
#     не разбором, вызвал ли его агент сам -- факт вычисляется, не
#     угадывается по тексту транскрипта.
#   - Требование: если последняя сессия этого РП имеет статус
#     "report.md есть" -- агент должен УЖЕ вызвать Read на путь её report.md
#     (проверяется фактом из транскрипта, не словами). Остальные статусы
#     (гэп/черновик/несогласованность) НЕ блокируют -- их цитирование
#     пилоту не наблюдаемо хуком механически (это прозаический текст, не
#     вызов инструмента), шаг 3.6 остаётся текстовой инструкцией для них;
#     сужено намеренно, не полная замена шага 3.6, только самая дорогую
#     половину (готовый отчёт, который реально не открыли).
#
# Маркер $STATE_DIR/handoff-confirmed-<session_id>-<WP> -- один раз на
# сессию+РП, не пере-сканировать на каждый Write/Edit (сканер быстрый,
# чисто локальный, но нет причины гонять его повторно после того как
# требование уже выполнено).
#
# Контракт PreToolUse hook (Claude Code): stdin JSON {tool_name,
# session_id, transcript_path, tool_input, ...}. JSON
# {"hookSpecificOutput": {..., "permissionDecision": "deny", ...}} на
# stdout блокирует; пустой вывод (exit 0) разрешает.

set -uo pipefail
export PATH="/run/current-system/sw/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
# shellcheck source=lib/ritual-detect.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ritual-detect.sh"

WP=$(ritual_prompt_wp_number "$TRANSCRIPT_PATH")
[ -n "$WP" ] || exit 0

CONFIRMED_MARKER="$STATE_DIR/handoff-confirmed-${SESSION_ID}-${WP}"
[ -f "$CONFIRMED_MARKER" ] && exit 0

export IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
export IWE_SCRIPTS="${IWE_SCRIPTS:-$IWE_ROOT/scripts}"
export IWE_SESSIONS_ROOT="${IWE_SESSIONS_ROOT:-$IWE_ROOT/MC-sessions}"
SCANNER="$IWE_SCRIPTS/wp-session-journal-gaps.sh"
[ -x "$SCANNER" ] || exit 0  # сканер недоступен -- шаг 3.6 остаётся текстовой инструкцией, не блокируем

SCAN_OUTPUT=$(bash "$SCANNER" "$WP" 2>/dev/null)
if [ -z "$SCAN_OUTPUT" ]; then
  mkdir -p "$STATE_DIR"
  : > "$CONFIRMED_MARKER"
  exit 0
fi

# Последняя строка -- последняя сессия этого РП (сканер сортирует по
# времени открытия и её не скрывает намеренно, см. комментарий в самом
# wp-session-journal-gaps.py:main()). Формат строки:
#   "  [статус-метка] <путь>/<slug> (<when>) — <rep>"
LAST_LINE=$(printf '%s\n' "$SCAN_OUTPUT" | tail -1)

if [[ "$LAST_LINE" != *"report.md есть"* ]]; then
  # Гэп/черновик/несогласованность -- не в этом хуке (см. заголовок).
  mkdir -p "$STATE_DIR"
  : > "$CONFIRMED_MARKER"
  exit 0
fi

SESSION_FOLDER=$(printf '%s' "$LAST_LINE" | sed -E 's/^  \[[^]]+\] ([^ ]+) .*/\1/')
if [ -z "$SESSION_FOLDER" ]; then
  # Не смогли распарсить строку -- fail open, не угадывать путь.
  mkdir -p "$STATE_DIR"
  : > "$CONFIRMED_MARKER"
  exit 0
fi

ALREADY_READ=$(transcript_has_read_of "$TRANSCRIPT_PATH" "${SESSION_FOLDER}/report.md")
if [ "$ALREADY_READ" = "yes" ]; then
  mkdir -p "$STATE_DIR"
  : > "$CONFIRMED_MARKER"
  exit 0
fi

SESSIONS_DIR="${IWE_SESSIONS_ROOT:-$IWE_ROOT/MC-sessions}"
REPORT_PATH="$SESSIONS_DIR/${SESSION_FOLDER}/report.md"
cat <<EOF
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Шаг 3.6 (protocol-open.md §Сессия): у $WP последняя сессия закрыта с готовым отчётом, но ты его не читал. Прочитай $REPORT_PATH (Read) ДО правки файлов -- её содержание («Дальше:») определяет формулировку «Работа» в Ритуале, не заголовок реестра."}}
EOF
exit 0
