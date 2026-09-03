#!/usr/bin/env bash
# write-path-lease-guard.sh — PreToolUse-хук (Edit|Write|MultiEdit|NotebookEdit):
# запись в защищённый манифестом путь требует активной аренды замка Local
# Gateway (WP-530, пир-сессия 2026-08-30-01, консенсус Claude+Kimi+Codex).
#
# Класс закрываемой дыры: интерактивный агент правит общий файл (карточка РП,
# реестр) напрямую, минуя CAS-контракт раннеров — две сессии затирают друг
# друга без сигнала. Раннеры и bash-записи хук не видит и не трогает: их
# защищает wp-context-guarded-edit; этот слой — только для tool-вызовов агента.
#
# Семантика (консенсус, exit 2 = блок для Claude Code):
#   файл не в манифесте            → пропустить молча
#   mode=telemetry, аренды нет     → пропустить + write_path_bypass в ledger
#   mode=enforce, аренда моя       → пропустить
#   mode=enforce, аренда чужая     → БЛОК (файл занят, назван держатель)
#   mode=enforce, аренды нет       → БЛОК (дана готовая команда acquire)
#   mode=enforce, шлюз недоступен  → БЛОК (fail-closed для shared/hot — консенсус)
#   IWE_WRITE_GUARD_BYPASS=1       → пропустить + write_path_bypass (аварийный ход)

set -uo pipefail

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HOOK_DIR/write-path-manifest.yaml"
IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GATEWAY_LOCK="$IWE_ROOT/$GOV_REPO/scripts/lib/gateway-lock.py"
IDENTITY_RESOLVER="$IWE_ROOT/$GOV_REPO/scripts/lib/iwe-agent-identity.sh"
# WP-484 (03.09, peer-session 2026-09-03-11-wp484-remaining-kimi-session-open,
# Kimi+Codex): the old inline "${IWE_AGENT_ID:-${IWE_AGENT:-claude-code}}"
# here never matched a lock acquired through the interactive MCP tool --
# proxy.js suffixes holder with $CLAUDE_CODE_SESSION_ID (WP-530 Ф19, 31.08),
# this hook didn't, so it always saw its own freshly-acquired lock as "held
# by another agent". Same resolver as gateway-lock.py now, so both agree.
AGENT_ID=$(bash "$IDENTITY_RESOLVER" 2>/dev/null) || AGENT_ID="claude-code"

[ -f "$MANIFEST" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {})
    # NotebookEdit адресует файл полем notebook_path (Codex, раунд 3).
    print(ti.get("file_path") or ti.get("notebook_path") or "")
except Exception:
    pass' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

# id класса и режим одним вызовом; пустой вывод = файл не под манифестом.
MATCH=$(python3 - "$MANIFEST" "$FILE_PATH" "$GOV_REPO" <<'PYEOF'
import fnmatch, os, sys
manifest, file_path, gov = sys.argv[1:4]
target = os.path.abspath(os.path.expanduser(file_path))
cls_id = mode = None
# Плоский парс двухуровневого YAML без внешних зависимостей: только ключи
# id/mode/patterns списка classes (структура манифеста намеренно такая простая).
for raw in open(manifest, encoding="utf-8"):
    line = raw.split("#", 1)[0].rstrip()
    s = line.strip()
    if s.startswith("- id:"):
        cls_id, mode = s.split(":", 1)[1].strip(), None
    elif s.startswith("mode:"):
        mode = s.split(":", 1)[1].strip()
    elif s.startswith("- ") and not s.startswith("- id:"):
        # Кавычки необязательны (cold review, Medium): неквотированный pattern
        # раньше молча выпадал из защиты -- fail-open через парсер.
        pat = s[2:].strip().strip("\"'").replace("{{GOV_REPO}}", gov)
        if cls_id and mode and pat and fnmatch.fnmatch(target, pat):
            print(f"{cls_id} {mode}")
            sys.exit(0)
PYEOF
)
[ -n "$MATCH" ] || exit 0
CLASS_ID="${MATCH%% *}"
MODE="${MATCH##* }"

emit_bypass() {  # $1=reason
  local ledger="$IWE_ROOT/$GOV_REPO/scripts/ledger-append.sh"
  [ -x "$ledger" ] || return 0
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({
      "file": sys.argv[1], "class": sys.argv[2], "reason": sys.argv[3],
      "agent": sys.argv[4]}))' \
    "$FILE_PATH" "$CLASS_ID" "$1" "$AGENT_ID" 2>/dev/null) || return 0
  bash "$ledger" day "$(date +%F)" write_path_bypass "$payload" \
    write-path-lease-guard >/dev/null 2>&1 \
    || echo "TELEMETRY_LOST: write_path_bypass не записан в ledger ($FILE_PATH)" >&2
}

if [ "${IWE_WRITE_GUARD_BYPASS:-0}" = "1" ]; then
  emit_bypass "env_bypass"
  exit 0
fi

LOCK_JSON=$(python3 "$GATEWAY_LOCK" check "$FILE_PATH" 2>/dev/null)
CHECK_RC=$?

if [ "$MODE" = "telemetry" ]; then
  # Причины различаются (cold review, Medium): неделя лежавшего шлюза не
  # должна выглядеть как неделя чистой телеметрии при решении об enforce.
  case "$CHECK_RC" in
    0) ;;
    3) emit_bypass "no_lease" ;;
    *) emit_bypass "gateway_unreachable" ;;
  esac
  exit 0
fi

case "$CHECK_RC" in
  0)
    HOLDER=$(printf '%s' "$LOCK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("holder",""))' 2>/dev/null)
    if [ "$HOLDER" = "$AGENT_ID" ]; then
      # Остаток аренды (cold review, Medium/TOCTOU): правка под истекающей
      # арендой может завершиться уже после перевыдачи замка другому.
      REMAIN_MS=$(printf '%s' "$LOCK_JSON" | python3 -c 'import json,sys,time
print(int(json.load(sys.stdin).get("expiresAt",0)) - int(time.time()*1000))' 2>/dev/null)
      if [ -n "$REMAIN_MS" ] && [ "$REMAIN_MS" -lt 10000 ]; then
        echo "write-path-lease-guard: твоя аренда на '$FILE_PATH' истекает (<10с) — продли её повторным acquire_file_lock (heartbeat сохранит токен) и повтори правку" >&2
        exit 2
      fi
      exit 0
    fi
    echo "write-path-lease-guard: файл занят другим агентом ($HOLDER) — общий файл класса $CLASS_ID. Дождись освобождения или согласуй с пилотом. Проверка: python3 $GATEWAY_LOCK check '$FILE_PATH'" >&2
    exit 2
    ;;
  3)
    # WP-484 (03.09, same session): NOT "IWE_AGENT_ID=$AGENT_ID ..." -- $AGENT_ID
    # here is already the fully resolved identity (base + session suffix).
    # gateway-lock.py resolves its own identity the same way this hook does
    # (same resolver, same environment) -- forcing an already-resolved value
    # back into IWE_AGENT_ID would make its resolver append the session
    # suffix a second time, producing a DIFFERENT identity than this hook
    # just computed (found live testing this exact fix, before it shipped).
    echo "write-path-lease-guard: запись в общий файл класса $CLASS_ID без аренды замка. Возьми аренду и повтори правку: mcp acquire_file_lock (или: python3 $GATEWAY_LOCK acquire '$FILE_PATH' 900), после записи — release. Аварийный обход (логируется): IWE_WRITE_GUARD_BYPASS=1" >&2
    exit 2
    ;;
  *)
    echo "write-path-lease-guard: шлюз замков недоступен, а файл — общий (класс $CLASS_ID, fail-closed). Подними Local Gateway (launchctl kickstart или ~/.iwe/gateway.pid) и повтори. Аварийный обход (логируется): IWE_WRITE_GUARD_BYPASS=1" >&2
    exit 2
    ;;
esac
