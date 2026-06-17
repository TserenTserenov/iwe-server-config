#!/usr/bin/env bash
# code-style-hook.sh — детектор-страховка инженерного стиля кода (WP-408 Ф3)
#
# Тип: Stop hook (проверяет код, написанный в завершённом ходу)
# Уровень: warning (nudge), не блокирует — всегда exit 0
# Лог: ~/.claude/logs/style-violations.log (тот же файл, что comm-детектор;
#      аггрегатор style-feedback-loop.py читает обе оси — A-правила и P-правила)
# Формат строки (контракт WP-388): TIMESTAMP | agent | rule | description | context(redacted)
#
# Детерминированные правила (консенсус peer-session 2026-06-10-11):
#   P1  тест без проверки результата:  assert True / expect(true).toBe(true)
#   P2  адресация переменной по строке: locals()[
#   P4  проглоченное исключение:        except ...: pass (без логирования)
#
# P5 (длина функции / число параметров) НЕ ловится: по diff-фрагменту честно
# не посчитать — отдано review-агенту v2 (см. DP.SC.172 §энфорсмент).
#
# Источник изменений: `git diff HEAD` в CLAUDE_PROJECT_DIR. Ограничение v1:
# покрывает основной репо проекта; вложенные суб-репо (отдельный .git) —
# зона v1.1. Детектор — страховка, первичный механизм = инжекция.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

AGENT="claude-code"
INPUT=$(cat 2>/dev/null || echo "")
[ -n "$INPUT" ] || exit 0

# Guard от рекурсии Stop-хука
if command -v jq >/dev/null 2>&1; then
  STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
  [ "$STOP_ACTIVE" = "true" ] && exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Только добавленные строки кода из diff (исключаем доки)
DIFF=$(git diff HEAD -- '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.sh' '*.go' '*.rs' '*.rb' '*.java' '*.sql' 2>/dev/null || echo "")
[ -n "$DIFF" ] || exit 0

LOG_FILE="${HOME}/.claude/logs/style-violations.log"
mkdir -p "$(dirname "$LOG_FILE")"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
VIOLATIONS=""

redact() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-100 \
    | sed -E 's/(gh[pousr]_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]+/<REDACTED>/g; s/[A-Za-z0-9_-]{32,}/<REDACTED>/g; s/[a-f0-9]{16,}/<REDACTED>/g; s/\|/¦/g'
}
log_violation() {
  local rule="$1" desc="$2" example="$3"
  VIOLATIONS="${VIOLATIONS}${rule} "
  echo "$TIMESTAMP | $AGENT | $rule | $desc | $(redact "$example")" >> "$LOG_FILE"
}

# Разбор diff на Python: смотрим только добавленные строки (начинаются с '+',
# но не '+++'). P4 — двухстрочный паттерн (except ...: затем pass).
PARSE=$(DIFF_TEXT="$DIFF" python3 - <<'PY' 2>/dev/null || echo ""
import os, re
diff = os.environ["DIFF_TEXT"]
added = []
for line in diff.splitlines():
    if line.startswith("+") and not line.startswith("+++"):
        added.append(line[1:])  # снять маркер '+'

hits = {}  # rule -> first matching example

def mark(rule, ex):
    hits.setdefault(rule, ex.strip())

# P1 — тест без проверки результата
re_p1 = re.compile(r'(\bassert\s+True\b|expect\(\s*true\s*\)\.toBe\(\s*true\s*\))')
# P2 — адресация переменной по строке
re_p2 = re.compile(r'locals\(\)\s*\[')
# P4 — except ...: pass (две формы: pass на той же строке или следующей)
re_p4_inline = re.compile(r'except\b[^:]*:\s*pass\s*$')
re_p4_head = re.compile(r'except\b[^:]*:\s*$')

for i, ln in enumerate(added):
    if re_p1.search(ln):
        mark("P1", ln)
    if re_p2.search(ln):
        mark("P2", ln)
    if re_p4_inline.search(ln):
        mark("P4", ln)
    elif re_p4_head.search(ln):
        # следующая добавленная строка — только pass?
        if i + 1 < len(added) and added[i + 1].strip() == "pass":
            mark("P4", ln + " / pass")

for rule in ("P1", "P2", "P4"):
    if rule in hits:
        # формат: RULE\texample (таб как разделитель, безопасен для shell read)
        print(f"{rule}\t{hits[rule]}")
PY
)

[ -n "$PARSE" ] || exit 0

while IFS=$'\t' read -r rule example; do
  [ -n "$rule" ] || continue
  case "$rule" in
    P1) log_violation "P1" "test-without-assertion" "$example" ;;
    P2) log_violation "P2" "locals-string-addressing" "$example" ;;
    P4) log_violation "P4" "swallowed-exception" "$example" ;;
  esac
done <<< "$PARSE"

[ -n "$VIOLATIONS" ] || exit 0

# Запахи уже записаны в лог-файл; в чат plain-text не выводим (Stop-хук → JSON,
# иначе «спецсимволы в конце сообщения», lessons_hook_json_safety.md). Тихо.
echo '{}'
exit 0
