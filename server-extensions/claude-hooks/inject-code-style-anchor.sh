#!/bin/bash
# inject-code-style-anchor.sh
# Event: UserPromptSubmit
# see DP.SC.172 (обещание «База инженерного стиля кода»), WP-408 Ф3
#
# Назначение: однострочный ЯКОРЬ. Сообщает агенту о существовании P0-P5 ДО
#   планирования правки (reasoning идёт до tool_use, поэтому полный впрыск на
#   PreToolUse приходит поздно для первой правки — combo решает это).
#
# Контракт композиции хуков стиля (delta-ArchGate WP-408, инвариант):
#   1. Хуки стиля не знают друг о друге.
#   2. State-файлы разделены префиксом: этот хук БЕЗ состояния; полный впрыск
#      inject-code-style.sh использует code-style-injected-* (не comm-style-*).
#   3. Контексты аддитивны — только добавляем additionalContext, ничего не отменяем.
#
# Поведение: stateless. Всегда одна строка. Не читает Pack, не пишет state.
# Полные правила доставляет inject-code-style.sh (PreToolUse Edit|Write).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# jq нужен для JSON. Нет jq → тихий валидный '{}' (не пустой stdout, иначе Claude Code не распарсит).
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

ANCHOR="🔧 Инженерный стиль кода активен (DP.SC.172): пишешь/правишь код → действуют P0-P5 (запахи с «было/стало»). Полные правила придут перед правкой код-файла. Тест: «вернётся ли кто-нибудь к этому коду?» Да → не плоди абстракции зря, реальные assert, без except: pass, мёртвые ветки удаляй."

jq -n --arg ctx "$ANCHOR" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
