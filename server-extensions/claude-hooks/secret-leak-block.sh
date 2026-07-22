#!/bin/bash
# Secret Leak Block Hook (B7.7a, WP-212)
# Event: PreToolUse (matcher: Bash)
# Блокирует Bash-команды содержащие плейнтекст-секреты.
# Покрывает ~85% command-driven утечек (см. WP-212 B7.7 feasibility analysis).
# НЕ покрывает: Claude-generated text без tool-use, Read файла с секретами.
#
# Bypass:
#   - env CC_ALLOW_SECRETS=1 (только из реального шелла пилота — хук читает
#     свой процессный env, не текст ещё не выполненной команды, поэтому
#     агент не может подставить это через саму Bash-команду)
#
# I9 (WP-458, 2026-07-17): маркер `# secret-ok` внутри команды убран —
# агент сам формирует эту строку, значит мог сам же вписать маркер и снять
# с себя же собственный стража. Единственный оставшийся bypass требует
# переменной окружения, которую агент не контролирует.
#
# Лог решений: ~/IWE/.claude/logs/secret-leak-block.jsonl

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-leak-block.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_decision() {
  local decision="$1" pattern="$2" cmd_head="$3"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc \
    --arg ts "$ts" \
    --arg sid "${CLAUDE_SESSION_ID:-}" \
    --arg dec "$decision" \
    --arg pat "$pattern" \
    --arg cmd "$cmd_head" \
    '{ts:$ts, hook:"secret-leak-block", session_id:$sid, decision:$dec, pattern:$pat, cmd_head:$cmd}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

# Read JSON input
input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
command=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Only check Bash
[ "$tool_name" != "Bash" ] && exit 0
[ -z "$command" ] && exit 0

# cmd_head для лога — РЕДАКТИРУЕМ секреты (B7.7c: сам лог не должен стать утечкой).
# Вычисляется ДО любого bypass/exit — до 2026-07-17 bypass-env/bypass-marker
# логировали "$command" как есть (72+4 живых секрета накопились в этом .jsonl
# за 12 дней, пока CC_ALLOW_SECRETS=1 стоял в settings.local.json; редакция
# постфактум + права 0600, см. WP-212 handoff).
cmd_head=$(printf '%s' "$command" | head -c 200 | sed -E \
  -e 's/napi_[A-Za-z0-9]{30,}/[REDACTED-NEON]/g' \
  -e 's#postgresql(ql)?://[^:[:space:]]+:[^@[:space:]]{6,}@#postgresql://[REDACTED]@#g' \
  -e 's/sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{30,}/[REDACTED-ANTHROPIC]/g' \
  -e 's/gh[poshru]_[A-Za-z0-9]{30,}/[REDACTED-GH]/g' \
  -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS]/g' \
  -e 's/ust_[A-Za-z0-9]{20,}/[REDACTED-BS]/g' \
  -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED-TG]/g')

# Bypass: env var (см. I9 note выше — единственный оставшийся путь)
if [ -n "${CC_ALLOW_SECRETS:-}" ]; then
  log_decision "bypass-env" "" "$cmd_head"
  exit 0
fi

# Patterns (в синтаксисе grep -E)
declare -a patterns=(
  "napi_[A-Za-z0-9]{30,}|Neon API key"
  "postgresql(ql)?://[^:[:space:]]+:[^@[:space:]]{6,}@|DATABASE_URL с user:pass"
  "sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{30,}|Anthropic API key"
  "gh[poshru]_[A-Za-z0-9]{30,}|GitHub token"
  "AKIA[0-9A-Z]{16}|AWS access key"
  "ust_[A-Za-z0-9]{20,}|Better Stack token"
  "[0-9]{8,10}:[A-Za-z0-9_-]{35}|Telegram bot token"
)

for entry in "${patterns[@]}"; do
  p="${entry%%|*}"
  label="${entry##*|}"
  if echo "$command" | grep -qE "$p"; then
    reason="Возможный секрет в Bash-команде (паттерн: $label). Если намеренно (тест/grep) — попроси пилота запустить с CC_ALLOW_SECRETS=1 (агент сам этот bypass выставить не может). Если реальный секрет — НЕ передавай через arg, используй \$VAR из env / wrapper из ~/IWE/.secrets/."
    log_decision "deny" "$label" "$cmd_head"
    jq -n \
      --arg reason "$reason" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
  fi
done

# === B7.7c: эвристика чтения секрет-ФАЙЛА через Bash-команду (палиатив) ===
# Покрывает обход secret-file-read-block.sh (тот висит на Read|Edit|Grep, не на Bash).
# Надёжнее было бы deny-by-default на уровне ядра Claude Code (разрешать только
# explicit tool_use), но это изменение ядра, не платформы. Здесь — расширяемый список
# read-инструментов + защита от escape (\) и переменных ($) (критика Kimi 2026-06-05).
# Снимаем escape (\) и кавычки ("') — обходы c\at / c""at / 'cat' (cold-review C4).
unescaped=$(printf '%s' "$command" | tr -d '\\"'\')
read_tools='cat|tac|rev|nl|head|tail|less|more|grep|egrep|fgrep|xxd|hexdump|od|strings|base64|openssl|jq|yq|python|python3|node|ruby|perl|awk|sed|dd|wc|tr|cut|paste|column|fmt|expand|tee|bat|mapfile|readarray|source'
# Граница слева ((^|[^A-Za-z0-9._-])) на каждом суб-паттерне: без неё "-secret\." матчил
# любую substring в тексте команды, не только реальный путь — заблокировало git commit -m
# с сообщением коммита, упоминающим имя файла claude-subscription-secret.nix (WP-7 21.07,
# живой инцидент). "-secret\." дополнительно сужен до типичных секрет-расширений
# (yaml/yml/json/env/txt/ini/conf) — "-secret.nix"/"-secret.sh" это код по имени, не секрет.
_b='(^|[^A-Za-z0-9._-])'
# secrets/*.(yaml|yml|json) без ведущей точки (sops-nix паттерн — repo secrets/google-calendar.yaml,
# claude-subscription.yaml) не был покрыт исходным ".secrets/"/"secrets\." (те требуют ведущую точку
# ИЛИ точку сразу после "secrets", ни один не матчит голый каталог) — обнаружено тем же живым тестом.
#
# "-secret\." БЕЗ границы _b слева (независимый живой тест, WP-7 21.07): _b требует
# не-word-символ перед началом матча — верно для путей вида ".secrets/foo" (сегмент с
# начала), но "-secret" сам ЕСТЬ суффикс имени файла (foo-secret.yaml, db-secret.yaml) —
# перед дефисом всегда стоит буква слова "foo"/"db", граница с _b там никогда не находится,
# и весь суб-паттерн переставал матчить реальные секрет-файлы этого вида. Расширение
# (yaml|yml|...) само по себе уже достаточно узкое — не нужна дополнительная граница.
sens_path="${_b}\\.secrets/|${_b}\\.railway/|${_b}\\.env([^A-Za-z0-9]|\$)|${_b}\\.env\\.|${_b}\\.pem([^A-Za-z0-9]|\$)|${_b}\\.p12|${_b}\\.pfx|${_b}/id_rsa|${_b}/id_ed25519|${_b}\\.token([^A-Za-z0-9]|\$)|-secret\\.(yaml|yml|json|env|txt|ini|conf)|${_b}/secrets\\.|${_b}secrets/[^[:space:]]*\\.(yaml|yml|json)|${_b}/credentials\\.|${_b}\\.netrc|${_b}wrangler\\.toml"
deny_read() {
  local why="$1"
  local reason="Чтение секрет-файла через Bash заблокировано (B7.7c, $why). Цепочка рвётся ДО попадания значения в контекст. Используй значение через \$VAR/env, не читай файл. Разовый легитимный дебаг — CC_ALLOW_SECRETS=1, выставленный пилотом в реальном шелле."
  log_decision "deny-bash-read" "$why" "$cmd_head"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}
# read-инструмент + sensitive-path (|$ — инструмент в конце строки: `xargs cat`, cold-review H2)
if echo "$unescaped" | grep -qE "(^|[^A-Za-z0-9])($read_tools)([^A-Za-z0-9]|$)" && echo "$unescaped" | grep -qE "$sens_path"; then
  deny_read "read-tool + sensitive-path"
fi
# POSIX dot-source (`. /path/.env`) — bare `.` не в read_tools (cold-review M3)
if echo "$unescaped" | grep -qE "(^|[;&|][[:space:]]*)\.[[:space:]]+[^[:space:]]*($sens_path)"; then
  deny_read "dot-source from sensitive-path"
fi
# редирект stdin из секрет-файла (`. < .secrets/x`, `while read < .env`) — без read-tool (cold-review C3)
if echo "$unescaped" | grep -qE "<[[:space:]]*[^[:space:]|&;]*($sens_path)"; then
  deny_read "stdin-redirect from sensitive-path"
fi
# Остаточный gap (палиатив): путь, полностью спрятанный в переменной (`F=.secrets/x; cat \$F`),
# не ловится — литерала пути в команде нет. Настоящий фикс = deny-by-default на уровне ядра
# Claude Code (разрешать только explicit tool_use), вне платформы. Покрыто слоями redact + value-patterns.

log_decision "allow" "" "$cmd_head"
exit 0
