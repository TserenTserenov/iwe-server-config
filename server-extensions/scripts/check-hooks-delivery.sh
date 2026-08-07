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
# правильным событием и matcher-группой с точным сопоставлением basename,
# относительного пути и порядка, неизменность относительно git HEAD
# (или pinned manifest, если есть), корректность разрешения команды в hook dir.
# ЧЕСТНАЯ ГРАНИЦА (консенсус): canary доказывает работоспособность hook-файла,
# но не факт его загрузки конкретной живой сессией Claude Code.
#
# Exit: 0 = всё доставлено; 1 = есть расхождения (детали в stdout).

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
HOOKS_DIR="$IWE/.claude/hooks"
SETTINGS="$IWE/.claude/settings.json"
MANIFEST="$HOOKS_DIR/.manifest.json"
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

# matcher → ожидаемый matcher для хука (empty = always-run группа без matcher)
expected_matcher() {
  case "$1" in
    close-runner-gate.sh) echo "Bash" ;;
    witness-write-guard.sh) echo "Write|Edit|MultiEdit|Bash" ;;
    *) echo "" ;;
  esac
}

echo "=== Аудит доставки хуков (Ф74в) ==="

# --- 1. Файлы: существование + исполняемость + неизменность vs manifest/git HEAD ---
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
    HASH_OUTDATED=0
    if [ -f "$MANIFEST" ]; then
      # Pinned manifest: sha256 файла должна совпадать с записанной
      EXPECTED=$(python3 - "$MANIFEST" "$hook" <<'PYEOF'
import json, sys, hashlib, hmac
manifest, name = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(manifest))
except Exception:
    sys.exit(1)
print(d.get("sha256", {}).get(name, ""))
PYEOF
)
      if [ -n "$EXPECTED" ]; then
        ACTUAL=$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
        if [ "$EXPECTED" != "$ACTUAL" ]; then
          fail "$hook: sha256 не совпадает с manifest (outdated)"
          HASH_OUTDATED=1
        fi
      fi
    fi
    if [ "$HASH_OUTDATED" -eq 0 ] && git -C "$IWE" rev-parse --git-dir >/dev/null 2>&1; then
      if ! git -C "$IWE" diff --quiet HEAD -- ".claude/hooks/$hook" 2>/dev/null; then
        fail "$hook: рабочая копия отличается от git HEAD (не задеплоенная правка?)"
        continue
      fi
    fi
    pass "$hook: файл на месте, исполняемый, совпадает с эталоном"
  done
done

# --- 2. Регистрация в settings.json: exact matcher/path/order verification ---
if [ ! -f "$SETTINGS" ]; then
  fail "settings.json отсутствует: $SETTINGS — НИД ОДИН хук не зарегистрирован"
else
  # Используем Python для точного сопоставления: каждый хук должен быть в правильной
  # matcher-группе, команда должна заканчиваться на .claude/hooks/<basename>,
  # порядок между группами сохраняется, нет лишних подстрокных совпадений.
  python3 - "$SETTINGS" "$HOOKS_DIR" <<'PYEOF' | while IFS=$'\t' read -r status hook msg; do
import json, sys, os, re
settings_path, hooks_dir = sys.argv[1], sys.argv[2]

events = {
    "UserPromptSubmit": ["close-gate-reminder.sh", "pilot-witness-recorder.sh"],
    "PreToolUse": ["close-runner-gate.sh", "witness-write-guard.sh"],
    "Stop": ["protocol-stop-gate.sh"],
}
expected_matcher = {
    "close-runner-gate.sh": "Bash",
    "witness-write-guard.sh": "Write|Edit|MultiEdit|Bash",
}

def matcher_matches(expected, actual):
    if not expected:
        return actual is None or actual == ""
    if actual is None:
        return False
    # Оба списка токенов; actual должен содержать все токены expected.
    expected_tokens = set(expected.split("|"))
    actual_tokens = set(actual.split("|"))
    return expected_tokens.issubset(actual_tokens)

try:
    settings = json.load(open(settings_path))
except Exception as exc:
    print(f"FAIL\tsettings.json\tне парсится: {exc}")
    sys.exit(0)

hooks_cfg = settings.get("hooks", {})

for event, required in events.items():
    groups = hooks_cfg.get(event, [])
    # flatten groups preserving order, extracting (matcher, command) for each hook
    entries = []
    for group in groups:
        matcher = group.get("matcher")
        for h in group.get("hooks", []):
            cmd = h.get("command", "")
            entries.append((matcher, cmd))
    idx = 0
    for req_hook in required:
        expected = expected_matcher.get(req_hook)
        found = False
        while idx < len(entries):
            matcher, cmd = entries[idx]
            # basename команды
            basename = cmd.split("/")[-1]
            # exact basename match (no substring)
            if basename != req_hook:
                idx += 1
                continue
            # matcher match
            if not matcher_matches(expected, matcher):
                print(f"FAIL\t{req_hook}\tзарегистрирован в {event}, но matcher {matcher!r} не совпадает с ожидаемым {expected!r}")
                idx += 1
                continue
            # path resolution: expand $CLAUDE_PROJECT_DIR to IWE root and verify it points to hooks_dir
            expanded = cmd.replace("$CLAUDE_PROJECT_DIR", hooks_dir.replace("/.claude/hooks", ""))
            if not os.path.normpath(expanded).startswith(os.path.normpath(hooks_dir) + os.sep):
                print(f"FAIL\t{req_hook}\tкоманда {cmd!r} не разрешается в hooks_dir")
                idx += 1
                continue
            # order check: found at or after current position
            print(f"OK\t{req_hook}\t{event} matcher={matcher or 'always'} pos={idx+1}")
            idx += 1
            found = True
            break
        if not found:
            print(f"FAIL\t{req_hook}\tне найден в {event} (или порядок нарушен)")
PYEOF
    if [ "$status" = "FAIL" ]; then
      fail "$hook: $msg"
    elif [ "$status" = "OK" ]; then
      pass "$hook: $msg"
    fi
  done
fi

# --- 3. Synthetic canary ---
CANARY_SID="hooks-delivery-canary-$$"

# close-runner-gate: доброкачественный вызов → exit 0 без вывода
if OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"%s"}' "$CANARY_SID" \
  | bash "$HOOKS_DIR/close-runner-gate.sh" 2>/dev/null); then
  if [ -z "$OUT" ]; then
    pass "canary: close-runner-gate.sh (benign → allow)"
  else
    fail "canary: close-runner-gate.sh не прошёл benign-вызов (unexpected output: ${OUT:0:80})"
  fi
else
  fail "canary: close-runner-gate.sh не прошёл benign-вызов (exit non-zero)"
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
if printf '{"prompt":"canary","session_id":"%s"}' "$CANARY_SID" \
  | bash "$HOOKS_DIR/pilot-witness-recorder.sh" >/dev/null 2>&1; then
  pass "canary: pilot-witness-recorder.sh (exit 0)"
else
  fail "canary: pilot-witness-recorder.sh exit != 0"
fi
rm -f "$IWE/.iwe-runtime/pilot-witness/$CANARY_SID.jsonl"

echo "=== Итог аудита: $FAIL расхождений ==="
[ "$FAIL" -eq 0 ]
