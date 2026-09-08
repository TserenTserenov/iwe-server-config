#!/bin/bash
# sync-extensions-auto-alert-smoke.sh — regression coverage for the alert()/
# alert_ok() escalation wrapper in scripts/sync-extensions-auto.sh
# (WP-538 Ф7, 08.09, peer-session with Kimi+Codex).
#
# Before this fix, every failed tick (this script runs every 2 hours via
# launchd) sent an identical raw Telegram message with zero suppression —
# a chronic sync-behind-origin condition could send 4+ near-identical
# messages a night. This test extracts the real alert()/alert_ok() function
# definitions from the production script (not a reimplementation) and drives
# them against the real notify_escalation_update() from DS-my-strategy, with
# curl stubbed on PATH to capture what would have gone to Telegram.
#
# Usage: bash scripts/tests/sync-extensions-auto-alert-smoke.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_SRC="$REPO_ROOT/scripts/sync-extensions-auto.sh"
[ -f "$SCRIPT_SRC" ] || { echo "не найден проверяемый скрипт: $SCRIPT_SRC"; exit 1; }
# SYNC_EXTENSIONS_NOTIFY_LIB — тот же override, что скрипт сам поддерживает
# (для тестов, чтобы не зависеть от актуальности канонического чекаута
# DS-my-strategy на этой машине — известная хроническая проблема этого РП).
NOTIFY_LIB="${SYNC_EXTENSIONS_NOTIFY_LIB:-$HOME/IWE/DS-my-strategy/scripts/lib/notification-render.sh}"
export SYNC_EXTENSIONS_NOTIFY_LIB="$NOTIFY_LIB"
[ -f "$NOTIFY_LIB" ] || { echo "не найдена notification-render.sh: $NOTIFY_LIB"; exit 1; }
grep -q "^notify_escalation_update()" "$NOTIFY_LIB" || { echo "notify_escalation_update отсутствует в $NOTIFY_LIB — укажи актуальную копию через SYNC_EXTENSIONS_NOTIFY_LIB"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — факт: ${2:-нет данных}"; FAIL=$((FAIL + 1)); }

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sync-extensions-auto-alert-smoke.XXXXXX")
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Извлекаем РЕАЛЬНОЕ определение alert()/alert_ok() из продового скрипта
# (не переписываем логику заново — иначе тест проверяет копию, а не код).
FUNCS_FILE="$WORKDIR/alert-funcs.sh"
awk '/^lock_acquire\(\)/{exit} /^ALERT_CLASSES=/{p=1} p' "$SCRIPT_SRC" > "$FUNCS_FILE"
[ -s "$FUNCS_FILE" ] || { echo "не удалось извлечь alert()/alert_ok() из $SCRIPT_SRC — сдвинулись маркеры-якоря?"; exit 1; }

TG_LOG="$WORKDIR/tg.log"
# shellcheck disable=SC2034  # используется внутри извлечённого alert() (echo "$LOG_PREFIX ...")
LOG_PREFIX="[test]"
touch "$TG_LOG"
FIX_BIN="$WORKDIR/bin"
mkdir -p "$FIX_BIN"
cat > "$FIX_BIN/curl" <<STUB
#!/bin/bash
# захватываем именно --data-urlencode "text=..." — тот же аргумент, что
# реальный send_telegram передаёт curl
for a in "\$@"; do
  case "\$a" in
    text=*) printf '%s\n' "\${a#text=}" >> "$TG_LOG" ;;
  esac
done
STUB
chmod +x "$FIX_BIN/curl"

export PATH="$FIX_BIN:$PATH"
export TELEGRAM_BOT_TOKEN="test-token"
export TELEGRAM_CHAT_ID="test-chat"
export DS_PUBLISH_ADMISSION_DIR="$WORKDIR/notify-admission"

# shellcheck source=/dev/null
. "$FUNCS_FILE"

# --- Сценарий 1: первый сбой класса "pull" — уходит сразу -------------------
: > "$TG_LOG"
alert pull "🚨 test: git pull провалился"
LINES=$(wc -l < "$TG_LOG" | tr -d ' ')
[ "$LINES" = "1" ] && ok "первый сбой: ровно одно сообщение" || bad "первый сбой: ровно одно сообщение" "$LINES строк"
grep -q "git pull провалился" "$TG_LOG" && ok "первый сбой: текст дошёл как есть" || bad "первый сбой: текст дошёл" "$(cat "$TG_LOG")"

# --- Сценарий 2: немедленный повтор того же класса — подавлен ---------------
: > "$TG_LOG"
alert pull "🚨 test: git pull провалился снова"
LINES=$(wc -l < "$TG_LOG" | tr -d ' ')
[ "$LINES" = "0" ] && ok "повтор внутри окна (360мин): подавлен, 0 сообщений" || bad "повтор внутри окна: 0 сообщений" "$LINES строк: $(cat "$TG_LOG")"

# --- Сценарий 3: другой класс ("push") не подавлен тем же окном, что "pull" -
: > "$TG_LOG"
alert push "🚨 test: push провалился"
LINES=$(wc -l < "$TG_LOG" | tr -d ' ')
[ "$LINES" = "1" ] && ok "другой класс не разделяет подавление с 'pull'" || bad "другой класс шлёт независимо" "$LINES строк"

# --- Сценарий 4: окно истекло — повтор уходит с пометкой "повторяется N раз" -
STATE_FILE="$DS_PUBLISH_ADMISSION_DIR/incidents/sync-extensions-auto-pull.state"
[ -f "$STATE_FILE" ] || bad "state-файл класса pull существует" "не найден $STATE_FILE"
OLD_TS=$(( $(date -u +%s) - 25000 ))  # > 360 мин
COUNT_NOW=$(cut -d: -f3 "$STATE_FILE")
printf '%s:%s:%s' "$OLD_TS" "$OLD_TS" "$COUNT_NOW" > "$STATE_FILE"
: > "$TG_LOG"
alert pull "🚨 test: git pull провалился в третий раз"
grep -q "повторяется" "$TG_LOG" && ok "окно истекло: текст содержит 'повторяется N раз'" || bad "окно истекло: текст содержит 'повторяется'" "$(cat "$TG_LOG")"

# --- Сценарий 5: успех снимает ОБА активных инцидента (pull И push — оба
# независимо упали на сценариях 1/3 выше) и отмечает оба в одном сообщении,
# не только последний по ALERT_CLASSES (cold-review WP-538 Ф7, 08.09: до
# фикса цикл в alert_ok перезаписывал recovered_from на каждой итерации,
# восстановление pull терялось молча).
: > "$TG_LOG"
alert_ok "✅ test: автосинк прошёл"
grep -q "восстановилось" "$TG_LOG" && ok "alert_ok: сообщает о восстановлении после реального инцидента" || bad "alert_ok: 'восстановилось' в тексте" "$(cat "$TG_LOG")"
grep -q "pull:" "$TG_LOG" && ok "alert_ok: восстановление класса pull не потеряно" || bad "alert_ok: упоминает pull" "$(cat "$TG_LOG")"
grep -q "push:" "$TG_LOG" && ok "alert_ok: восстановление класса push не потеряно" || bad "alert_ok: упоминает push" "$(cat "$TG_LOG")"

# --- Сценарий 6: следующий success без предшествующего сбоя — без ложной "восстановилось" ---
: > "$TG_LOG"
alert_ok "✅ test: снова прошло"
LINES=$(wc -l < "$TG_LOG" | tr -d ' ')
[ "$LINES" = "1" ] && ok "чистый успех: ровно одно сообщение" || bad "чистый успех: ровно одно сообщение" "$LINES строк"
if grep -q "восстановилось" "$TG_LOG"; then
    bad "чистый успех: НЕ должен упоминать 'восстановилось' (ложная тревога)" "$(cat "$TG_LOG")"
else
    ok "чистый успех: не упоминает 'восстановилось' (нечего восстанавливать)"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
