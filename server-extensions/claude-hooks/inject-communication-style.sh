#!/bin/bash
# inject-communication-style.sh
# Event: UserPromptSubmit
# see DP.SC.050 (обещание «Единый разговорный стиль агентов»), WP-388 Ф8
#
# Назначение: доставить S0 базовый разговорный стиль (SoT в Pack) + S1 авторские
#             надстройки в контекст Claude Code ПЕРЕД ответом. Заменяет хрупкую
#             вклейку маркер-блока в генерируемые CLAUDE.md / AGENTS.md (которые
#             перезаписываются template-sync.sh / sync-agent-instructions.sh).
#
# Архитектура (WP-388 Ф8, АрхГейт пройден):
#   S0 = PACK-digital-platform/.../02-domain-entities/communication-style-base.md (read-only)
#   S1 = DS-my-strategy/memory/communication-style-author.md (additive-only,
#        только через личный диспетчер — доступен только автору с PACK-rhetoric)
#   S2 = memory/communication-style-personal.md (additive-only, файл-fallback — WP-412 Ф13,
#        тот же механизм, что у обычного пользователя шаблона без диспетчера).
#   Доставка = этот хук (UserPromptSubmit). Генерируемые файлы не трогаются.
#
# Поведение (density-based reinjection, peer-session 2026-06-08-23):
# - Освежается по ходу сессии: первый ход + при росте переписки (не один раз)
# - L0-файл отсутствует → silent skip (echo '{}')
# - L1-файл отсутствует → инжектим только L0
# - Пороги: STYLE_REINJECT_TURNS (12), STYLE_REINJECT_BYTES (60000)
# - Каждый ход: подсказка A13.1 о прошлом ответе (a13-1-next-turn-hint.py, РП-388 Ф36),
#   выключатель IWE_STYLE_NEXT_TURN_HINT=0
# - Каждый ход: строка главного правила A0 (РП-388 Ф39) — полный стиль приходит
#   раз в 12 ходов, а в долгой технической сессии агент между впрысками пишет
#   языком собственного рабочего журнала. Выключатель IWE_STYLE_A0_EVERY_TURN=0
#   (не зависит от выключателя подсказок).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# jq нужен для вывода JSON. Нет jq → тихий валидный '{}', не пустой stdout (иначе Claude Code не распарсит).
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
# Пустой/битый id → unknown; санитизация против path traversal в имени state-файла
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/comm-style-injected-$SESSION_ID"

# Density-based reinjection: впрыск НЕ один раз за сессию, а освежается по ходу.
# Триггер: первый ход ИЛИ прошло >= N ходов ИЛИ выросло >= M байт стенограммы.
REINJECT_EVERY_TURNS="${STYLE_REINJECT_TURNS:-12}"
REINJECT_BYTES="${STYLE_REINJECT_BYTES:-60000}"

# Текущий объём контекста — размер стенограммы (если харнесс её передал)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
CUR_BYTES=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CUR_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)
  [ -n "$CUR_BYTES" ] || CUR_BYTES=0
fi

# Состояние: "turn last_inject_turn last_inject_bytes"
TURN=0; LAST_INJECT_TURN=0; LAST_INJECT_BYTES=0
if [ -f "$STATE_FILE" ]; then
  read -r TURN LAST_INJECT_TURN LAST_INJECT_BYTES < "$STATE_FILE" 2>/dev/null || true
  [ -n "${TURN:-}" ] || TURN=0
  [ -n "${LAST_INJECT_TURN:-}" ] || LAST_INJECT_TURN=0
  [ -n "${LAST_INJECT_BYTES:-}" ] || LAST_INJECT_BYTES=0
fi
TURN=$((TURN + 1))

DO_INJECT=0
if [ ! -f "$STATE_FILE" ]; then
  DO_INJECT=1                                                   # первый ход
elif [ $((TURN - LAST_INJECT_TURN)) -ge "$REINJECT_EVERY_TURNS" ]; then
  DO_INJECT=1                                                   # по числу ходов
elif [ "$CUR_BYTES" -gt 0 ] && [ $((CUR_BYTES - LAST_INJECT_BYTES)) -ge "$REINJECT_BYTES" ]; then
  DO_INJECT=1                                                   # по объёму переписки
fi

# $1 = additionalContext text; empty → '{}' (Claude Code needs valid JSON on stdout).
emit_context() {
  if [ -z "$1" ]; then echo '{}'; return; fi
  jq -n --arg ctx "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "UserPromptSubmit",
      "additionalContext": $ctx
    }
  }'
}

# Main rule A0 (РП-388 Ф39, pilot's decision 03.11): one line on every turn, on
# every exit below, before the hints. Text mirrors CLAUDE.md A0 and pack rule
# "Главное правило".
A0_LINE=""
if [ "${IWE_STYLE_A0_EVERY_TURN:-1}" != "0" ]; then
  A0_LINE="Главное правило стиля (A0, пилот её не видит): сначала — результат и что он значит для пилота, словами, понятными человеку, который не видел твоей работы; нужные ссылки — рядом с пунктом; слова внутренней кухни IWE (корень, канон, боевой, изолированная копия, холодная проверка) — простыми понятными словами, если пилот сам их не употребляет."
fi

# $1, $2 … non-empty parts joined by a blank line.
join_parts() {
  local out="" part
  for part in "$@"; do
    [ -n "$part" ] || continue
    if [ -n "$out" ]; then out="$out

$part"; else out="$part"; fi
  done
  printf '%s' "$out"
}

# Next-turn hint for A13.1 (РП-388 Ф36 step 5): replaces the old A13.1 block, which
# produced a second visible message. Runs on every turn, independent of reinjection.
# Off switch: IWE_STYLE_NEXT_TURN_HINT=0.
NEXT_TURN_HINT=""
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${IWE_STYLE_NEXT_TURN_HINT:-1}" != "0" ] && [ -n "$TRANSCRIPT_PATH" ]; then
  PROMPT_TEXT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")
  mkdir -p "$HOME/.claude/logs" 2>/dev/null || true
  NEXT_TURN_HINT=$(PROMPT="$PROMPT_TEXT" SESSION_ID="$SESSION_ID" \
    python3 -B "$HOOK_DIR/a13-1-next-turn-hint.py" "$TRANSCRIPT_PATH" \
    2>>"$HOME/.claude/logs/style-next-turn-hints.err" || echo "")
fi

# Не пора впрыскивать — обновить счётчик хода и выйти (подсказка, если есть, всё равно уходит)
if [ "$DO_INJECT" -eq 0 ]; then
  mkdir -p "$STATE_DIR"
  echo "$TURN $LAST_INJECT_TURN $LAST_INJECT_BYTES" > "$STATE_FILE"
  emit_context "$(join_parts "$A0_LINE" "$NEXT_TURN_HINT")"
  exit 0
fi

# Контент: диспетчер реестра (если доступен) → файл-снимок s0-core.md → пропуск.
# Диспетчер: WP-412 Ф6 (тонкий хук с каскадом L0+L1+author). Путь к нему через PROJECT_DIR.
# Файл-снимок: WP-412 Ф11 (FMT-fallback, самодостаточен). Путь через BASH_SOURCE — работает в env -i.
# Рантайм-механика (переинъекция, state) остаётся в хуке. Откат: git revert.
S0_CORE="$HOOK_DIR/../styles/s0-core.md"

DISPATCHER="$PROJECT_DIR/PACK-rhetoric/pack/language-style/registry/dispatcher.py"
# Session-pinned snapshot of the packs (lib/style-pin.sh, WP-539); any failure keeps the live one.
# shellcheck source=lib/style-pin.sh
if [ -f "$HOOK_DIR/lib/style-pin.sh" ] && . "$HOOK_DIR/lib/style-pin.sh"; then
  PINNED=$(style_pin_dispatcher "$PROJECT_DIR" "$SESSION_ID" 2>/dev/null) && [ -n "$PINNED" ] && DISPATCHER="$PINNED"
fi
if [ -f "$DISPATCHER" ]; then
  FRAGMENT=$(python3 "$DISPATCHER" --event userpromptsubmit-ide --quiet --no-cache 2>/dev/null)
fi

# Если диспетчер не дал контент — читаем файл-снимок (обрезаем frontmatter между --- --- )
if [ -z "${FRAGMENT:-}" ] && [ -f "$S0_CORE" ]; then
  FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$S0_CORE" 2>/dev/null)
fi

[ -n "${FRAGMENT:-}" ] || { emit_context "$(join_parts "$A0_LINE" "$NEXT_TURN_HINT")"; exit 0; }   # оба источника пусты/упали → только подсказка (safe)

# S2: личный оверрайд пользователя шаблона (WP-412 Ф13). Отдельный файл от
# шаблона-образца (communication-style-personal-template.md) — его хук
# никогда не читает, иначе placeholder-инструкция попала бы в промпт как
# «стиль пользователя» на каждой чистой установке. Пусто/нет файла → просто
# не добавляем, FRAGMENT остаётся как был (additive-only, не блокирует S0).
PERSONAL_OVERRIDE="$PROJECT_DIR/memory/communication-style-personal.md"
if [ -f "$PERSONAL_OVERRIDE" ]; then
  PERSONAL_FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$PERSONAL_OVERRIDE" 2>/dev/null)
  if [ -n "${PERSONAL_FRAGMENT//[$' \t\n']/}" ]; then
    FRAGMENT="$FRAGMENT

$PERSONAL_FRAGMENT"
  fi
fi

CONTEXT="## 🗣 Разговорный стиль IWE (S0 база + S1 автор) — применять при ответе человеку

Источник истины: \`DP.SC.050\` (Pack). Канал-детектор: технический режим — для стенограмм/commit/PR; «на пальцах» — для чата с пилотом и §1-§4 синтеза report.md.

$FRAGMENT"

# Записать state: текущий ход = последний впрыск, запомнить байты стенограммы
mkdir -p "$STATE_DIR"
echo "$TURN $TURN $CUR_BYTES" > "$STATE_FILE"

# Cleanup старых state-файлов (>24h)
find "$STATE_DIR" -name "comm-style-injected-*" -mmin +1440 -delete 2>/dev/null || true

emit_context "$(join_parts "$A0_LINE" "$CONTEXT" "$NEXT_TURN_HINT")"
