#!/bin/bash
# Close Runner Gate (PreToolUse, WP-482 «Reflex-принуждение к раннеру», 25.07.2026)
#
# Проблема, которую решает: protocol-close.md с 17.07 прямо называет раннер
# «обязательным драйвером Quick Close, первое действие» — 24.07 LLM прочитал
# эту фразу буквально и всё равно выполнил шаги Close вручную (git commit,
# WP-context, MEMORY.md) в обход process-runner.py. Текстовая инструкция
# внутри протокола, который сам же LLM интерпретирует, не была механизмом
# принуждения — LLM может рационализировать замену собственными шагами, когда
# конечный результат по фактам совпадает. Этот хук — сам вход в раннер как
# рефлекс: не текст, а структурная проверка перед прямым git commit.
#
# Что НЕ делает: не блокирует прохождение ai-контрактных шагов раннера
# (wp-context-update и т.п.) — им по-прежнему нужен LLM. Блокирует только
# путь «Close объявлен в этой сессии, но карточка раннера ещё не создана,
# а LLM уже пытается закоммитить руками».
#
# Известные обходы (не закрыты этой версией, задокументированы намеренно —
# фикс регэкспа под каждый вариант git-инвокации даёт гонку вооружений, не
# решение; первая версия честного гейта закрывает самый частый путь):
# `git -c x=y commit`, `(git commit ...)` в subshell, `$(git commit ...)`
# в command substitution, `git commit-tree`/`git commit-graph` (эти два —
# ложный ПОЗИТИВ, не обход: plumbing-команды не создают commit истории
# закрытия сессии, но матчатся тем же regex).
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - Exit 0 = allow; exit 2 = block (stderr = причина, показывается LLM).

set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0
SESSION_ID_SAFE=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID_SAFE" ] || exit 0

RUNNER_MARKER_DIR="/tmp/iwe-close-runner-started"
RUNNER_MARKER="$RUNNER_MARKER_DIR/$SESSION_ID_SAFE.flag"

# Наблюдаем ЛЮБОЙ Bash-вызов этой сессии, стартующий quick-close через раннер —
# отмечаем session-bound маркер сразу, независимо от того, что произойдёт с
# commit'ом ниже. Это решает race condition из независимой проверки: карточка
# RUN-quick-close-*.md в общем каталоге не несёт session_id (WP-482 не меняет
# process-runner.py под эту правку), поэтому сравнение "есть ли где-то свежая
# карточка" путало параллельные сессии друг с другом (сессия A видела карточку,
# запущенную сессией B, и ложно считала раннер своим). Маркер этого хука
# session-bound по построению — привязан к session_id из PreToolUse payload,
# который Claude Code не путает между параллельными агентами.
if echo "$COMMAND" | grep -qE 'process-runner\.py[[:space:]]+start[[:space:]]+quick-close'; then
  mkdir -p "$RUNNER_MARKER_DIR" 2>/dev/null
  touch "$RUNNER_MARKER" 2>/dev/null
fi

# Применимо к блокировке только прямой git commit. process-runner.py сам
# вызывает git commit внутри commit-push.sh как subprocess — PreToolUse видит
# только верхний Bash-вызов LLM (`python3 process-runner.py ...`), не увидит
# вложенный git commit отдельным tool call, поэтому раннер этим гейтом не
# блокируется независимо от маркера выше.
echo "$COMMAND" | grep -qE '(^|[;&|]|&&)\s*git commit' || exit 0

SENTINEL="/tmp/iwe-close-intent/$SESSION_ID_SAFE.flag"
# Close не объявлен в этой сессии (или sentinel не создан) — не мешать штатной работе.
[ -f "$SENTINEL" ] || exit 0

# TTL: Quick Close — сессия ~3 мин, но между «закрывай» и commit могут быть
# уточняющие ходы. 30 минут — с запасом, не session-lifetime (файл не растёт
# бесконечно: одна сессия перезаписывает свой sentinel при повторном «закрывай»).
case "$(uname)" in
  Darwin) MTIME=$(stat -f %m "$SENTINEL" 2>/dev/null) ;;
  *)      MTIME=$(stat -c %Y "$SENTINEL" 2>/dev/null) ;;
esac
[ -n "$MTIME" ] || exit 0
NOW=$(date +%s)
if [ $((NOW - MTIME)) -gt 1800 ]; then
  rm -f "$SENTINEL" 2>/dev/null
  exit 0
fi

# session-bound маркер — не общий каталог карточек. Гонка с параллельными
# сессиями невозможна: маркер лежит по session_id ЭТОЙ сессии, никакая другая
# сессия не может его создать или случайно совпасть именем.
[ -f "$RUNNER_MARKER" ] && exit 0

SENTINEL_CREATED=$(jq -r '.created_at // empty' "$SENTINEL" 2>/dev/null)
echo "[close-runner-gate] session=$SESSION_ID_SAFE close-intent=$SENTINEL_CREATED no process-runner.py start quick-close observed in this session — blocking direct git commit" >&2

cat >&2 <<EOF
🚫 Reflex-принуждение к раннеру (WP-482): прямой git commit в обход process-runner.py заблокирован.

В этой сессии объявлено намерение закрыть сессию ($SENTINEL_CREATED), но вызова
"process-runner.py start quick-close" в этой же сессии не наблюдалось.

protocol-close.md называет раннер обязательным первым действием Quick Close — этот
гейт делает требование механическим, не полагаясь на то, что текст был прочитан
буквально (найдено живьём 24.07: LLM продублировал шаги Close руками, несмотря на
прямую инструкцию в тексте протокола).

Сначала:
  cd DS-my-strategy && python3 scripts/process-runner.py start quick-close --slug <slug> \\
    --input '{"agent":"<agent>","slug":"<slug>","session_file":"<путь или null>","repos":["<repo1>", ...]}'

Раннер сам вызовет commit-push через свой хендлер — этот git commit тогда не потребуется напрямую.
EOF
exit 2
