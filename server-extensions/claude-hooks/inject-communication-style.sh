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
# Поведение (WP-7 Ф299, пир-сессия 2026-11-05-05-wp7-system-prompt-budget, Claude+Kimi+Codex):
# - Платформа держит в контексте не больше 10 000 символов вывода одного хука, остальное
#   уводит в файл и показывает модели 2 КБ превью (замер 05.11, lib/platform_limits.py).
#   Полный стиль ~26K символов поэтому НЕ впрыскивается целиком: lib/style_rotation.py режет его
#   по границам правил на части ≤ 5 000 (7 000 − 2 000 запаса под A0, манифест и подсказку) и отдаёт по одной части за ход (разогрев — все части
#   подряд в начале сессии, дальше «Дальше:» и онтология раз в 3 хода, прочее раз в 12).
#   Ни одно правило не выбрасывается (запрет удаления, решение пилота 05.11.2026).
# - Каждый ход: строка-манифест части, строка главного правила A0 (РП-388 Ф39, выключатель
#   IWE_STYLE_A0_EVERY_TURN=0) и подсказка A13.1 (РП-388 Ф36, IWE_STYLE_NEXT_TURN_HINT=0).
# - Весь вывод хука ≤ 7 000 символов (0,7 × лимит); журнал доставки ~/.claude/logs/style-delivery.log.
# - Нет источника стиля → только A0 и подсказка (fail-open).
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

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
mkdir -p "$STATE_DIR"

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

# Rotation: one part of the full style per turn, whole output capped (lib/style_rotation.py).
# The log dir must exist before the 2>> redirect below, or the shell fails the redirect,
# python never runs and the style is silently not delivered (found by /verify, F299).
mkdir -p "$HOME/.claude/logs" 2>/dev/null || true
SOURCE_FILE="$STATE_DIR/comm-style-source-$SESSION_ID.md"
ROTATION_STATE="$STATE_DIR/comm-style-rotation-$SESSION_ID.json"
printf '%s' "$CONTEXT" > "$SOURCE_FILE"
ROTATED=$(STYLE_PREFIX="$A0_LINE" STYLE_SUFFIX="$NEXT_TURN_HINT" python3 -B "$HOOK_DIR/lib/style_rotation.py" \
  --source "$SOURCE_FILE" --state "$ROTATION_STATE" --session "$SESSION_ID" \
  --log "$HOME/.claude/logs/style-delivery.log" 2>>"$HOME/.claude/logs/style-rotation.err") \
  || ROTATED=$(join_parts "$A0_LINE" "$NEXT_TURN_HINT")
# The fallback above bypasses the rotation's cap: never let it outgrow the harness limit,
# drop the hint first (an oversized hook output is not delivered at all).
if [ "$(printf '%s' "$ROTATED" | python3 -c 'import sys; print(len(sys.stdin.read()))')" -gt 7000 ]; then
  ROTATED="$A0_LINE"
fi

# Cleanup old per-session state (>24h)
find "$STATE_DIR" \( -name "comm-style-injected-*" -o -name "comm-style-source-*" -o -name "comm-style-rotation-*" \) \
  -mmin +1440 -delete 2>/dev/null || true

emit_context "$ROTATED"
