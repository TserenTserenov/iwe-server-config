#!/bin/bash
# check-hooks-delivery.sh — WP-484 Ф74в (07.08.2026, консенсус пир-сессии
# 2026-08-07-08-quick-close-runner-bypass): независимый аудит доставки
# обязательных хуков контура Close (close + witness).
#
# Зачем: 4/4 случая blocked-witness-unavailable (Ф56 доп./Ф73) и обход Quick
# Close 07.08 имеют один корень — хук на диске есть, но в settings.json не
# подключён (или машина/проект вне скоупа). SessionStart-хук не может
# обнаружить отсутствие собственной регистрации — поэтому проверка живёт
# ВНЕ хук-контура и запускается из конвейеров (day-open-checks-runner).
#
# Проверяет: наличие + исполняемость файлов, регистрацию в settings.json под
# правильным событием с сохранением относительного порядка, неизменность
# относительно git HEAD, synthetic canary-вызов.
# ЧЕСТНАЯ ГРАНИЦА (консенсус): canary доказывает работоспособность hook-файла,
# но не факт его загрузки конкретной живой сессией Claude Code.
#
# Exit: 0 = всё доставлено; 1 = есть расхождения (детали в stdout).

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
HOOKS_DIR="$IWE/.claude/hooks"
SETTINGS="$IWE/.claude/settings.json"
FAIL=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# event → упорядоченный список обязательных хуков (порядок значим).
# bash 3.2 (macOS) не имеет assoc arrays — списки через case.
EVENTS=("UserPromptSubmit" "PreToolUse" "Stop")
required_hooks() {
  case "$1" in
    UserPromptSubmit) echo "close-gate-reminder.sh pilot-witness-recorder.sh" ;;
    PreToolUse)       echo "close-runner-gate.sh witness-write-guard.sh" ;;
    Stop)             echo "protocol-stop-gate.sh" ;;
  esac
}

echo "=== Аудит доставки хуков (Ф74в) ==="

# --- 1. Файлы: существование + исполняемость + неизменность vs git HEAD ---
for event in "${EVENTS[@]}"; do
  for hook in $(required_hooks "$event"); do
    f="$HOOKS_DIR/$hook"
    if [ ! -f "$f" ]; then
      fail "$hook: файл отсутствует"
      continue
    fi
    if [ ! -x "$f" ]; then
      fail "$hook: не исполняемый"
      continue
    fi
    # На Nix-развёрнутых хостах (tsekh-1) ~/IWE может не быть git-репо —
    # там проверка неизменности неприменима, пропускаем молча.
    if git -C "$IWE" rev-parse --git-dir >/dev/null 2>&1; then
      if ! git -C "$IWE" diff --quiet HEAD -- ".claude/hooks/$hook" 2>/dev/null; then
        fail "$hook: рабочая копия отличается от git HEAD (не задеплоенная правка?)"
        continue
      fi
    fi
    pass "$hook: файл на месте, исполняемый, совпадает с HEAD"
  done
done

# --- 2. Регистрация в settings.json (событие + относительный порядок) ---
if [ ! -f "$SETTINGS" ]; then
  fail "settings.json отсутствует: $SETTINGS — НИ ОДИН хук не зарегистрирован"
else
  for event in "${EVENTS[@]}"; do
    registered=$(python3 - "$SETTINGS" "$event" <<'PYEOF'
import json, sys
settings, event = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(settings))
except Exception:
    sys.exit(2)
cmds = []
for group in d.get("hooks", {}).get(event, []):
    for h in group.get("hooks", []):
        cmds.append(h.get("command", ""))
print("\n".join(cmds))
PYEOF
)
    if [ $? -eq 2 ]; then
      fail "settings.json не парсится"
      break
    fi
    prev_idx=-1
    for hook in $(required_hooks "$event"); do
      idx=$(printf '%s\n' "$registered" | grep -n "$hook" | head -1 | cut -d: -f1)
      if [ -z "$idx" ]; then
        fail "$hook: НЕ зарегистрирован в $event ($SETTINGS)"
        continue
      fi
      if [ "$prev_idx" -ge 0 ] && [ "$idx" -le "$prev_idx" ]; then
        fail "$hook: порядок регистрации в $event нарушен (позиция $idx после $prev_idx)"
        continue
      fi
      prev_idx=$idx
      pass "$hook: зарегистрирован в $event (позиция $idx)"
    done
  done
fi

# --- 3. Synthetic canary ---
CANARY_SID="hooks-delivery-canary-$$"

# close-runner-gate: доброкачественный вызов → exit 0 без вывода
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"%s"}' "$CANARY_SID" \
  | bash "$HOOKS_DIR/close-runner-gate.sh" 2>/dev/null)
if [ $? -eq 0 ] && [ -z "$OUT" ]; then
  pass "canary: close-runner-gate.sh (benign → allow)"
else
  fail "canary: close-runner-gate.sh не прошёл benign-вызов"
fi

# close-gate-reminder: фраза закрытия → sentinel + инструкция run-protocol
OUT=$(printf '{"prompt":"закрывай","session_id":"%s"}' "$CANARY_SID" \
  | bash "$HOOKS_DIR/close-gate-reminder.sh" 2>/dev/null)
if [ -f "/tmp/iwe-close-intent/$CANARY_SID.flag" ] && printf '%s' "$OUT" | grep -q "run-protocol"; then
  pass "canary: close-gate-reminder.sh (close-intent → sentinel + инструкция)"
else
  fail "canary: close-gate-reminder.sh не создал sentinel/инструкцию"
fi
rm -f "/tmp/iwe-close-intent/$CANARY_SID.flag"
# canary arm'ит obligation для фиктивной сессии — чистим напрямую (state, не ledger)
CANARY_HASH=$(printf '%s' "$CANARY_SID" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:32])')
rm -f "$IWE/.iwe-runtime/close-obligation/$CANARY_HASH.json" "$IWE/.iwe-runtime/close-obligation/$CANARY_HASH.lock"

# protocol-stop-gate: несуществующий транскрипт → '{}'
OUT=$(printf '{"transcript_path":"/nonexistent","session_id":"%s"}' "$CANARY_SID" \
  | bash "$HOOKS_DIR/protocol-stop-gate.sh" 2>/dev/null)
if [ "$OUT" = '{}' ]; then
  pass "canary: protocol-stop-gate.sh (нет транскрипта → {})"
else
  fail "canary: protocol-stop-gate.sh вернул неожиданное: ${OUT:0:80}"
fi

# pilot-witness-recorder / witness-write-guard: живой вызов с валидным JSON → exit 0
printf '{"prompt":"canary","session_id":"%s"}' "$CANARY_SID" \
  | bash "$HOOKS_DIR/pilot-witness-recorder.sh" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  pass "canary: pilot-witness-recorder.sh (exit 0)"
else
  fail "canary: pilot-witness-recorder.sh exit != 0"
fi
rm -f "$IWE/.iwe-runtime/pilot-witness/$CANARY_SID.jsonl"

echo "=== Итог аудита: $FAIL расхождений ==="
[ "$FAIL" -eq 0 ]
