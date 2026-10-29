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
# WP-568 Ф10: the script sends through the shared Telegram library
# (SYNC_EXTENSIONS_TG_LIB). A stub library captures the text and whether the
# send was marked as needing the pilot's decision (the live-chat ticket).
DECISION_LOG="$WORKDIR/decision.log"
touch "$DECISION_LOG"
STUB_LIB="$WORKDIR/telegram-stub.sh"
cat > "$STUB_LIB" <<STUB
telegram_send() {
  printf '%s\\n' "\$1" >> "$TG_LOG"
  printf '%s\\t%s\\n' "\${TELEGRAM_SOURCE_ID:-}" "\${TELEGRAM_NEEDS_DECISION:-0}" >> "$DECISION_LOG"
  TELEGRAM_SEND_OUTCOME=sent
}
STUB
export SYNC_EXTENSIONS_TG_LIB="$STUB_LIB"
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
# NOTIFY_ESCALATION_URGENT_AFTER_SEC переопределён на время сценария (WP-7
# Ф174, 24.09.2026): дефолт urgent-after-sec (21600) и repeat-after-min*60
# (360*60=21600) — одно и то же число, поэтому любой возраст инцидента,
# достаточный, чтобы миновать окно подавления, ОДНОВРЕМЕННО пересекает и
# urgent-порог — фактический текст всегда получался "🆘 ... нужно ручное
# вмешательство" (urgent), а не проверяемое здесь "повторяется" (ongoing).
# Сценарий 4 проверяет именно фазу ongoing — отодвигаем urgent далеко, чтобы
# два условия снова не совпадали случайно.
NOTIFY_ESCALATION_URGENT_AFTER_SEC=999999
STATE_FILE="$DS_PUBLISH_ADMISSION_DIR/incidents/sync-extensions-auto-pull.state"
[ -f "$STATE_FILE" ] || bad "state-файл класса pull существует" "не найден $STATE_FILE"
OLD_TS=$(( $(date -u +%s) - 25000 ))  # > 360 мин (окно подавления), но < urgent выше
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
[ "$LINES" = "0" ] && ok "чистый успех: сообщения нет (рутина, только в лог)" || bad "чистый успех: сообщения нет" "$LINES строк: $(cat "$TG_LOG")"
if grep -q "восстановилось" "$TG_LOG"; then
    bad "чистый успех: НЕ должен упоминать 'восстановилось' (ложная тревога)" "$(cat "$TG_LOG")"
else
    ok "чистый успех: не упоминает 'восстановилось' (нечего восстанавливать)"
fi

# --- Сценарий 8: длительный простой пересекает urgent-порог — пилот видит
# растущую длительность немедленно, минуя обычное окно подавления (WP-538
# Ф12: "счётчик дошёл до попытки #12, пилот видел «конвейер стоит» без
# нового повода действовать" — симптом РОВНО этого отсутствующего пути до
# того, как --urgent-after-sec появился в alert()). Отдельный класс
# ("sync-script"), чтобы не делить state с сценариями 1-6 выше.
# Сценарий 4 выше навсегда переопределил NOTIFY_ESCALATION_URGENT_AFTER_SEC
# на 999999 (простая переменная, не subshell) — вернуть реальный дефолт
# скрипта, иначе этот сценарий проверяет порог, которого в проде не будет.
NOTIFY_ESCALATION_URGENT_AFTER_SEC=21600
: > "$TG_LOG"
alert sync-script "🚨 test: sync-extensions.sh упал (попытка 1)"
LINES=$(wc -l < "$TG_LOG" | tr -d ' ')
[ "$LINES" = "1" ] && ok "urgent: первый сбой класса sync-script уходит сразу" \
    || bad "urgent: первый сбой уходит сразу" "$LINES строк"

STATE_FILE_URGENT="$DS_PUBLISH_ADMISSION_DIR/incidents/sync-extensions-auto-sync-script.state"
[ -f "$STATE_FILE_URGENT" ] || bad "urgent: state-файл класса sync-script существует" "не найден $STATE_FILE_URGENT"
# Отодвигаем first_seen на 7ч (> дефолтного urgent-after-sec=21600с=6ч в
# alert()) — тот же приём, что сценарий 4 использует для repeat-окна.
OLD_TS_URGENT=$(( $(date -u +%s) - 25200 ))
COUNT_URGENT=$(cut -d: -f3 "$STATE_FILE_URGENT")
printf '%s:%s:%s' "$OLD_TS_URGENT" "$OLD_TS_URGENT" "$COUNT_URGENT" > "$STATE_FILE_URGENT"
: > "$TG_LOG"
alert sync-script "🚨 test: sync-extensions.sh упал (попытка N)"
grep -q "🆘" "$TG_LOG" && ok "urgent: сообщение помечено как требующее вмешательства (🆘)" \
    || bad "urgent: 🆘 в тексте" "$(cat "$TG_LOG")"
grep -qE "так уже [0-9]+ч" "$TG_LOG" && ok "urgent: названа длительность простоя в часах (с момента последнего успеха, не первого отказа)" \
    || bad "urgent: длительность в часах" "$(cat "$TG_LOG")"
grep -qE "[0-9]+ попыт.* подряд" "$TG_LOG" && ok "urgent: названо число попыток подряд" \
    || bad "urgent: число попыток подряд" "$(cat "$TG_LOG")"
grep -q "разбери доставку расширений" "$TG_LOG" && ok "urgent: явно назван следующий шаг (фраза для агента)" \
    || bad "urgent: назван следующий шаг" "$(cat "$TG_LOG")"
[ "$(tail -1 "$DECISION_LOG")" = "$(printf 'sync-extensions-auto\t1')" ] && ok "urgent: отправка помечена «нужно решение пилота» (пропуск в живой чат)" \
    || bad "urgent: флаг решения" "$(tail -1 "$DECISION_LOG")"
head -1 "$DECISION_LOG" | grep -q "	0$" && ok "первый сбой: без флага решения (уходит в утреннюю сводку)" \
    || bad "первый сбой: без флага решения" "$(head -1 "$DECISION_LOG")"

# --- Сценарий 9: сразу после urgent-отправки — подавлено (не каждые 2ч спам) ---
: > "$TG_LOG"
alert sync-script "🚨 test: sync-extensions.sh упал (попытка N+1, тот же тик цикла)"
LINES=$(wc -l < "$TG_LOG" | tr -d ' ')
[ "$LINES" = "0" ] && ok "urgent: повтор сразу после urgent-отправки подавлен (не спамит на каждый 2ч-тик)" \
    || bad "urgent: повтор сразу после urgent подавлен" "$LINES строк: $(cat "$TG_LOG")"

# --- Сценарий 10: восстановление после urgent-инцидента называет итоговую
# длительность простоя ("одно сообщение о восстановлении с длительностью",
# Ф12 приёмка) — не просто "попыток, Xч", а прошедшую через urgent фазу.
: > "$TG_LOG"
alert_ok "✅ test: автосинк прошёл после долгого простоя"
grep -q "sync-script:" "$TG_LOG" && ok "urgent: восстановление после urgent-инцидента называет класс и длительность" \
    || bad "urgent: восстановление называет sync-script" "$(cat "$TG_LOG")"

# --- Сценарий 7: нет библиотеки отправки — предупреждение, не молчание ----
# WP-7 Ф174 (24.09.2026): пропавшая отправка не должна быть неотличима в
# логе от штатного подавления. После WP-568 Ф10 токен проверяет сама
# библиотека; здесь — случай, когда её файла нет на хосте.
(
  : > "$TG_LOG"
  SYNC_EXTENSIONS_TG_LIB="$WORKDIR/missing-telegram.sh"
  TG_LIB="$SYNC_EXTENSIONS_TG_LIB"
  send_telegram "test: нет библиотеки"
) >"$WORKDIR/scenario7.log" 2>&1
if grep -q "library not found" "$WORKDIR/scenario7.log"; then
  ok "нет библиотеки: предупреждение в логе"
else
  bad "нет библиотеки: предупреждение в логе" "$(cat "$WORKDIR/scenario7.log")"
fi
LINES=$(wc -l < "$TG_LOG" | tr -d ' ')
[ "$LINES" = "0" ] && ok "нет библиотеки: ничего не отправлено мимо неё" || bad "нет библиотеки: ничего не отправлено" "$LINES строк"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
