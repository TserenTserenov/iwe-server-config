#!/usr/bin/env bash
# Exercise delivery acknowledgement and retry state without a network call.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/git"
# Load only the alert functions: the full entrypoint also inspects a checkout.
sed -n '/^tg_alert() {/,/^repo_has_operation() {/p' "$ROOT/scripts/git-dirty-guard.sh" | sed '$d' > "$FIXTURE/functions.sh"
source "$FIXTURE/functions.sh"
GIT_DIR="$FIXTURE/git"
REPO=fixture
GIT_DIRTY_GUARD_TG_ALERTS=true
CALLS="$FIXTURE/calls"
RESPONSE='{"ok":true}'
TRANSPORT_RC=0
curl() { printf 'called\n' >> "$CALLS"; printf '%s' "$RESPONSE"; return "$TRANSPORT_RC"; }
export TELEGRAM_BOT_TOKEN=fixture-token TELEGRAM_CHAT_ID=fixture-chat
STATE="$GIT_DIR/dirty-guard-alert-state"
send() { alert_dedup_send differ-chronic fixed 'Хроническое расхождение' 'Проверьте синхронизацию'; }
count() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else printf 0; fi; }
assert_pending() { [ ! -e "$STATE" ] || { echo 'failed delivery consumed dedup state' >&2; exit 1; }; }

unset TELEGRAM_BOT_TOKEN
if send; then echo 'missing credentials accepted' >&2; exit 1; fi
assert_pending
[ "$(count)" = 0 ]
export TELEGRAM_BOT_TOKEN=fixture-token
TRANSPORT_RC=7
if send; then echo 'transport failure accepted' >&2; exit 1; fi
assert_pending
TRANSPORT_RC=0
RESPONSE='{"ok":false}'
if send; then echo 'API failure accepted' >&2; exit 1; fi
assert_pending
RESPONSE='not-json'
if send; then echo 'malformed acknowledgement accepted' >&2; exit 1; fi
assert_pending
RESPONSE='{"ok":true}'
send
grep -q '^version=2$' "$STATE"
BEFORE=$(count)
send
[ "$(count)" = "$BEFORE" ]

# v1 recorded attempts, so it must not suppress the first verified delivery.
sed 's/version=2/version=1/' "$STATE" > "$STATE.tmp"
mv "$STATE.tmp" "$STATE"
send
[ "$(count)" = "$((BEFORE + 1))" ]
grep -q '^version=2$' "$STATE"

# Failed escalation must retain the last acknowledged timestamp for retry.
sed 's/last_alerted_at=.*/last_alerted_at=1/' "$STATE" > "$STATE.tmp"
mv "$STATE.tmp" "$STATE"
cp "$STATE" "$FIXTURE/before"
TRANSPORT_RC=28
if send; then echo 'failed escalation accepted' >&2; exit 1; fi
cmp "$STATE" "$FIXTURE/before"
TRANSPORT_RC=0
send
! grep -q '^last_alerted_at=1$' "$STATE"

# Pull-on-touch intentionally has alerts disabled and must not consume TTL.
rm "$STATE"
GIT_DIRTY_GUARD_TG_ALERTS=false
BEFORE=$(count)
send
assert_pending
[ "$(count)" = "$BEFORE" ]
echo 'delivery acknowledgement, migration, escalation retry, silent inspection: OK'
