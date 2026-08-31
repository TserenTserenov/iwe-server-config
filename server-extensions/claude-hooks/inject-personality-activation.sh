#!/bin/bash
# inject-personality-activation.sh
# Event: UserPromptSubmit
# WP-510 Ф32 — mechanical enforcement of «Конвенция активации по обращению»
# (AI Personalities Registry.md § Протокол представления): accepted
# 2026-08-06, written down as a rule 2026-08-13, found unenforced again
# 2026-08-30 — the rule existed only as prose the executor had to recall
# every session, unlike the role-prefix convention below which already had
# a real hook. This is that same mechanism for personality names.
#
# Mirrors inject-role-prefixes.sh: a cheap grep-only check covers the
# common no-match case (no python spawned); reserved names are read
# dynamically from the registry's "Команда одним взглядом" table, so a new
# named personality needs no edit here.
#
# Safety property this hook must keep: never activate a personality that
# isn't this host's bound active_writer (Запрет неподтверждённых заявлений
# — addressing "Кир" on a Claude Code session must not fake Кир's passport
# just because the name is reserved somewhere in the registry).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')
PROMPT=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null | head -c 200 || echo "")
[ -n "$PROMPT" ] || { echo '{}'; exit 0; }

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "${HOOK_DIR}/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" 2>/dev/null || { echo '{}'; exit 0; }

REGISTRY="$IWE_DS_MY_STRATEGY/current/AI Personalities Registry.md"
[ -f "$REGISTRY" ] || { echo '{}'; exit 0; }

# Reserved names are the bold first cell of each row in "Команда одним
# взглядом" (stop at the next subsection, not the next "##" heading, since
# the surrounding prose also uses "**bold**" spans that aren't names).
NAMES=$(awk '/^## Команда одним взглядом/{f=1; next} f && /^### Старт для нового участника/{exit} f' "$REGISTRY" 2>/dev/null | \
  grep -o '\*\*[^*]*\*\*' | sed 's/\*\*//g' | awk '{print $1}' | sort -u)
[ -n "$NAMES" ] || { echo '{}'; exit 0; }

PATTERN=$(printf '%s\n' "$NAMES" | tr '\n' '|' | sed 's/|$//')
[ -n "$PATTERN" ] || { echo '{}'; exit 0; }

MATCHED_NAME=$(printf '%s' "$PROMPT" | grep -oiE "^(${PATTERN})[,!:]" | head -1 | sed -E 's/[,!:]$//')
[ -n "$MATCHED_NAME" ] || { echo '{}'; exit 0; }

command -v python3 >/dev/null 2>&1 || { echo '{}'; exit 0; }

# Cheap check passed — resolve which personality this host actually carries
# as active_writer (same lookup session-start-guard.sh runs at SessionStart).
RESOLVER="$IWE_DS_MY_STRATEGY/scripts/resolve-personality-by-host.py"
[ -f "$RESOLVER" ] || { echo '{}'; exit 0; }

RESOLVE_JSON=$(python3 "$RESOLVER" --registry "$REGISTRY" --hostname "$(hostname)" 2>/dev/null)
[ -n "$RESOLVE_JSON" ] || { echo '{}'; exit 0; }
[ "$(printf '%s' "$RESOLVE_JSON" | jq -r '.status // empty' 2>/dev/null)" = "matched" ] || { echo '{}'; exit 0; }

PID=$(printf '%s' "$RESOLVE_JSON" | jq -r '.personality_id // empty' 2>/dev/null)
[ -n "$PID" ] || { echo '{}'; exit 0; }

PROJECTOR="$IWE_DS_MY_STRATEGY/scripts/build-personality-context-projection.py"
[ -f "$PROJECTOR" ] || { echo '{}'; exit 0; }

PROJECTION=$(python3 "$PROJECTOR" --personality-id "$PID" --task "$PROMPT" --role "$MATCHED_NAME" --channel "claude-code" --registry "$REGISTRY" 2>/dev/null)
[ -n "$PROJECTION" ] || { echo '{}'; exit 0; }

BOUND_FIRST_NAME=$(printf '%s' "$PROJECTION" | jq -r '.core.name // empty' 2>/dev/null | awk '{print $1}')
[ -n "$BOUND_FIRST_NAME" ] || { echo '{}'; exit 0; }

if [ "$(printf '%s' "$MATCHED_NAME" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$BOUND_FIRST_NAME" | tr '[:upper:]' '[:lower:]')" ]; then
  echo '{}'
  exit 0
fi

CONTEXT="## 🪪 Активация по обращению (реестр личностей, «Конвенция активации по обращению»)

Сообщение начинается с «${MATCHED_NAME}, …» — паспорт поднят автоматически, поднимать сборщиком повторно не нужно. Действуй по протоколу представления: короткая подпись + обычное человеческое приветствие в первом ответе, дальше в этом сеансе — от лица личности (её персона, намерения, полномочия и запреты из паспорта ниже), не называя техническую реализацию по имени. Если «Статус» ниже не \`active\` — сообщи статус прямо, не притворяйся активной.

${PROJECTION}"

jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
