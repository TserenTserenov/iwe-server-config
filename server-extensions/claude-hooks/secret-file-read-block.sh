#!/bin/bash
# Secret File Read Block Hook (B7.7c, WP-212)
# Event: PreToolUse (matcher: Read|Edit|MultiEdit|Grep)
# Рвёт цепочку утечки ДО попадания содержимого секрет-файла в контекст агента.
#
# Зачем (B7.7c, отличие от B7.7a/b):
#   - B7.7a (secret-leak-block.sh) ловит секреты в Bash-КОМАНДАХ, но не Read файла.
#   - B7.7b (secret-leak-redact.sh) редактирует PostToolUse — СЛИШКОМ ПОЗДНО:
#     оригинал уже в conversation transcript (= ушёл в Anthropic API).
#   - Этот хук = PreToolUse DENY: файл с секретом не читается вовсе.
#
# Принципы:
#   - FAIL-CLOSED: baseline-денилист захардкожен. Хук НЕ зависит от наличия .agentigore.
#     Нет файла паттернов → baseline всё равно блокирует.
#   - Scope = ТОЛЬКО секреты (не PII/бинарники). Главный агент обязан читать pdf/png/
#     reflection — поэтому полный .agentigore (peer-transfer-фильтр) здесь НЕ применяется.
#   - Bypass = path-scoped (один файл), не session-global. Blast radius = 1 файл.
#
# Bypass:
#   - CC_ALLOW_SECRET_PATH=<abs-path>  — разрешает ровно этот файл (realpath match). Logged.
#   - CC_ALLOW_SECRETS=1               — emergency override пилота (вся сессия). Logged как emergency.
#
# Лог решений: ~/IWE/.claude/logs/secret-file-read-block.jsonl
# see also: AR.111, DP.RUNBOOK.003, peer-session 2026-06-05-17

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-file-read-block.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_decision() {
  local decision="$1" pattern="$2" path_head="$3"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc \
    --arg ts "$ts" \
    --arg sid "${CLAUDE_SESSION_ID:-}" \
    --arg dec "$decision" \
    --arg pat "$pattern" \
    --arg path "$path_head" \
    '{ts:$ts, hook:"secret-file-read-block", session_id:$sid, decision:$dec, pattern:$pat, path:$path}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)

case "$tool_name" in
  Read|Edit|MultiEdit) fp_field=".tool_input.file_path" ;;
  Grep)                fp_field=".tool_input.path" ;;
  *) exit 0 ;;
esac

# Array-path guard (cold-review M1): если путь — массив, jq отдаст многострочье →
# basename даст мусор → silent allow. Deny-closed: массив путей не парсим безопасно.
fp_type=$(echo "$input" | jq -r "$fp_field | type" 2>/dev/null)
if [ "$fp_type" = "array" ]; then
  log_decision "deny" "array-path (deny-closed)" "$(echo "$input" | jq -rc "$fp_field" 2>/dev/null | head -c 120)"
  jq -n --arg reason "Путь передан массивом — не парсится безопасно, блокирую (fail-closed). Читай файлы по одному." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
fi

target=$(echo "$input" | jq -r "$fp_field // empty" 2>/dev/null)

# Пустой target (например Grep по cwd) — нечего таргетировать тут; Bash/redact слои покрывают.
[ -z "$target" ] && exit 0

# Нормализация для матчинга (cold-review C1/C2):
#   - lowercase: macOS APFS регистронезависима → .PEM/.ENV читают тот же файл, должны блокироваться;
#   - strip trailing space/dot: `x.env ` / `x.env.` резолвятся в реальный файл, не должны обходить.
base=$(basename "$target")
base_n=$(printf '%s' "$base" | sed -E 's/[[:space:].]+$//' | tr 'A-Z' 'a-z')
target_n=$(printf '%s' "$target" | tr 'A-Z' 'a-z')

# --- Исключения (шаблоны без секретов) ---
case "$base_n" in
  *.example|*.sample|*.template|*.dist|*.example.*|*.sample.*)
    log_decision "allow-template" "$base" "$target"; exit 0 ;;
esac

# --- Baseline secret denylist (FAIL-CLOSED, не зависит от файлов) ---
matched=""
# по пути (директории-зоны секретов)
case "/$target_n/" in
  */.secrets/*) matched=".secrets/ dir" ;;
  */.railway/*) matched=".railway/ dir" ;;
esac
# по basename (нормализованному)
if [ -z "$matched" ]; then
  case "$base_n" in
    .env|.env.*|*.env)                 matched="*.env" ;;
    *.pem|*.key|*.p12|*.pfx)           matched="private-key" ;;
    *.token)                            matched="*.token" ;;
    id_rsa|id_rsa.*|id_ed25519|id_ed25519.*) matched="ssh-key" ;;
    *-secret.*|secrets.*|credentials.*) matched="secret/creds file" ;;
    .netrc|.proxy-env|.proxy-secret)   matched=".netrc/proxy" ;;
    wrangler.toml)                      matched="wrangler.toml" ;;
  esac
fi

# --- Доп. паттерны из ~/.iwe/secret-read-extra.deny (опционально, расширяемость) ---
EXTRA="$HOME/.iwe/secret-read-extra.deny"
if [ -z "$matched" ] && [ -f "$EXTRA" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    # shellcheck disable=SC2254
    case "$base_n" in $pat) matched="extra:$pat"; break ;; esac
    case "/$target_n/" in *"/$pat/"*) matched="extra-dir:$pat"; break ;; esac
  done < "$EXTRA"
fi

# Не секрет → пропускаем
[ -z "$matched" ] && exit 0

# === Файл — секрет. Проверяем bypass. ===

# Emergency override пилота (вся сессия)
if [ "${CC_ALLOW_SECRETS:-}" = "1" ]; then
  log_decision "emergency-override" "$matched" "$target"
  exit 0
fi

# Path-scoped one-file allow
if [ -n "${CC_ALLOW_SECRET_PATH:-}" ]; then
  rp_target=$(realpath "$target" 2>/dev/null || echo "$target")
  rp_allow=$(realpath "$CC_ALLOW_SECRET_PATH" 2>/dev/null || echo "$CC_ALLOW_SECRET_PATH")
  if [ "$rp_target" = "$rp_allow" ]; then
    log_decision "path-allow-used" "$matched" "$target"
    exit 0
  fi
fi

# DENY
reason="Чтение файла с секретом заблокировано (B7.7c, паттерн: $matched). Цепочка утечки рвётся ДО попадания значения в контекст. Если нужно именно это значение — НЕ читай файл: используй его через shell (\$VAR из env / wrapper из .secrets/). Если чтение легитимно (например, разовый дебаг ровно этого файла) — запусти сессию с CC_ALLOW_SECRET_PATH=$(realpath "$target" 2>/dev/null || echo "$target"). Глобальный обход (вся сессия) — только CC_ALLOW_SECRETS=1, по явному решению пилота."
log_decision "deny" "$matched" "$target"
jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
