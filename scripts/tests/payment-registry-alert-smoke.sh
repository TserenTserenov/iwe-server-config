#!/bin/bash
# payment-registry-alert-smoke.sh — coverage for scripts/payment-registry-alert.sh
# (WP-568, 02.11). Runs the real script with curl, journalctl and flock stubbed
# on PATH; every line curl receives is one chat message.
#
# Usage: bash scripts/tests/payment-registry-alert-smoke.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/payment-registry-alert.sh"

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — факт: ${2:-нет данных}"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/home"
export HOME="$SANDBOX/home" SENT="$SANDBOX/sent" JOURNAL="$SANDBOX/journal"
export CURL_RC_FILE="$SANDBOX/curl-rc"
export TELEGRAM_BOT_TOKEN=test TELEGRAM_CHAT_ID=111 TELEGRAM_TEAM_CHAT_ID=""
: > "$SENT"
STATE="$HOME/IWE/.claude/state/failure-alert/payment-registry"

cat > "$SANDBOX/bin/curl" <<'STUB'
#!/bin/bash
rc=$(cat "$CURL_RC_FILE" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
while [ $# -gt 0 ]; do
  case "$1" in --data-urlencode) printf '%s\n===\n' "${2#text=}" >> "$SENT"; shift ;; esac
  shift
done
STUB
cat > "$SANDBOX/bin/journalctl" <<'STUB'
#!/bin/bash
cat "$JOURNAL" 2>/dev/null
STUB
printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/flock"
# The shared gateway: queues the line for the digest (DIGEST_MODE=deferred) or
# reports a live delivery (sent), as the real iwe-tg does on its stderr.
export DIGEST="$SANDBOX/digest" DIGEST_MODE_FILE="$SANDBOX/digest-mode"
cat > "$SANDBOX/bin/iwe-tg" <<'STUB'
#!/bin/bash
mode=$(cat "$DIGEST_MODE_FILE" 2>/dev/null || echo deferred)
case "$mode" in
  deferred) printf '%s\n===\n' "${@: -1}" >> "$DIGEST" ;;
  sent)     printf '%s\n===\n' "${@: -1}" >> "$SENT" ;;   # the library sent it live
  refused)  echo "iwe-tg: quarantined" >&2; exit 3 ;;
esac
echo "iwe-tg: outcome=$mode" >&2
STUB
chmod +x "$SANDBOX/bin/"*
export PATH="$SANDBOX/bin:$PATH"

P=payment-registry-sync-payment.service
C=payment-registry-sync-contract.service
S=payment-registry-sync-subscription.service
count() { grep -c '^===$' "$SENT"; }
run() { bash "$SCRIPT" "$@"; }
age_announcement() { echo "$(( $(date +%s) - $1 ))" > "$STATE/announced-at"; }

echo "Сценарий: один сбой на три службы всю ночь"
echo 'FAIL: Cannot read Aisystant snapshot: psql: error: timeout expired' > "$JOURNAL"
run failure "$P"
[ "$(count)" = 1 ] && ok "первый сбой: одно сообщение сразу" || bad "первый сбой" "$(count)"
grep -q "не читается база Aisystant" "$SENT" && ok "причина названа" || bad "причина" "$(cat "$SENT")"
grep -q "(платежи)" "$SENT" && ok "служба названа" || bad "служба" "$(cat "$SENT")"
for _ in 1 2 3 4 5 6 7 8; do run failure "$P" >/dev/null; run failure "$C" >/dev/null; run failure "$S" >/dev/null; done
[ "$(count)" = 1 ] && ok "24 сбоя трёх служб внутри окна: без новых сообщений" || bad "подавление" "$(count)"

grep -q "при восстановлении. Пока простой длится" "$SENT" && ok "первое сообщение обещает чат только при восстановлении" || bad "обещание" "$(cat "$SENT")"

echo "Сценарий: истекло окно повтора, сводка работает (WP-568 Ф12 П5)"
age_announcement 21601
run failure "$S"
[ "$(count)" = 1 ] && ok "после 6 часов: в чат ничего" || bad "повтор в чат" "$(count)"
grep -q "обмена нет уже" "$DIGEST" && ok "повтор ушёл в сводку и говорит о длительности" || bad "повтор в сводке" "$(cat "$DIGEST" 2>&1)"
grep -q "договоры, платежи, подписки" "$DIGEST" && ok "повтор перечисляет все три службы" || bad "перечень" "$(cat "$DIGEST")"
run failure "$P" >/dev/null
[ "$(grep -c '^===$' "$DIGEST")" = 1 ] && ok "сразу после повтора снова тишина и в сводке" || bad "после повтора" "$(cat "$DIGEST")"

echo "Сценарий: истекло окно, сводку на хосте не читают"
echo sent > "$DIGEST_MODE_FILE"
age_announcement 21601
run failure "$S" 2>/dev/null
[ "$(count)" = 2 ] && ok "повтор пришёл в чат один раз (шлюз отправил сам, без дубля)" || bad "повтор без сводки" "$(count)"


echo "Сценарий: восстановление"
run success "$P"
run success "$S"
[ "$(count)" = 2 ] && ok "пока одна служба падает, о восстановлении не сообщаем" || bad "ранний успех" "$(count)"
run success "$C"
[ "$(count)" = 3 ] && ok "все три прошли: одно сообщение о восстановлении" || bad "восстановление" "$(count)"
grep -q "обмен восстановлен" "$SENT" && ok "текст восстановления" || bad "текст восст." "$(tail -3 "$SENT")"
run success "$C"; run success "$P"
[ "$(count)" = 3 ] && ok "штатные успехи после восстановления молчат" || bad "успехи" "$(count)"

echo "Сценарий: новый инцидент после восстановления"
: > "$JOURNAL"
run failure "$C"
[ "$(count)" = 4 ] && ok "новый инцидент объявляется сразу" || bad "новый инцидент" "$(count)"
grep -q "по журналу не определена" "$SENT" && ok "неизвестная причина названа честно" || bad "неизвестная причина" "$(tail -8 "$SENT")"
run success "$C"

echo "Сценарий: отправка не удалась"
echo 'FAIL: Cannot read Aisystant snapshot' > "$JOURNAL"
echo 22 > "$CURL_RC_FILE"
run failure "$P"; rc=$?
[ "$rc" != 0 ] && ok "сбой отправки виден кодом возврата" || bad "код возврата" "$rc"
[ ! -f "$STATE/announced-at" ] && ok "неотправленное не считается объявленным" || bad "метка" "$(cat "$STATE/announced-at")"
rm -f "$CURL_RC_FILE"
before=$(count)
run failure "$P"
[ "$(count)" = "$((before + 1))" ] && ok "следующий тик досылает" || bad "досылка" "$(count)"

echo "Сценарий: журнал не попадает в чат"
run success "$P"
echo 'FAIL: Cannot read Aisystant snapshot secret-row-email@example.org' > "$JOURNAL"
run failure "$P"
grep -q 'example.org' "$SENT" && bad "строка журнала ушла в чат" "$(tail -6 "$SENT")" || ok "в чат идут только готовые фразы"

echo "Сценарий: командный чат недоступен"
run success "$P"
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/bin/bash
case "$*" in *chat_id=222*) exit 22 ;; esac
while [ $# -gt 0 ]; do
  case "$1" in --data-urlencode) printf '%s\n===\n' "${2#text=}" >> "$SENT"; shift ;; esac
  shift
done
STUB
before=$(count)
TELEGRAM_TEAM_CHAT_ID=222 run failure "$P" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(count)" = "$((before + 1))" ] && [ -f "$STATE/announced-at" ] \
  && ok "сбой командной копии не считается сбоем объявления" || bad "командный чат" "rc=$rc"

echo "Сценарий: чужая служба"
run failure iwe-other.service 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "чужая служба отклонена" || bad "чужая служба" "$rc"

echo "Сценарий: шлюз отказал"
echo refused > "$DIGEST_MODE_FILE"
age_announcement 21601
before=$(count)
run failure "$S" 2>/dev/null
[ "$(count)" = "$((before + 1))" ] && ok "отказ шлюза: повтор не теряется, прямая отправка" || bad "отказ шлюза" "$(count)"
rm -f "$DIGEST_MODE_FILE"

echo ""
echo "Итог: успешно $PASS, провалов $FAIL"
[ "$FAIL" = 0 ]
