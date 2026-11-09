#!/usr/bin/env bash
# Exercise delivery outcome handling and retry state without a network call.
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
# WP-568 Ф12 С4: tg_alert sends through iwe-notify next to the script; the
# fixture copy of it records the call and prints the outcome line under test.
OUTCOME=sent
export CALLS OUTCOME
cat > "$FIXTURE/iwe-notify" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = --source ] && [ "$2" = git-dirty-guard ] || { echo "bad args: $*" >&2; exit 64; }
printf 'called\n' >> "$CALLS"
[ "$OUTCOME" = none ] || printf 'iwe-notify: outcome=%s\n' "$OUTCOME"
FAKE
chmod +x "$FIXTURE/iwe-notify"
STATE="$GIT_DIR/dirty-guard-alert-state"
send() { alert_dedup_send differ-chronic fixed 'Хроническое расхождение' 'Проверьте синхронизацию'; }
count() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else printf 0; fi; }
assert_pending() { [ ! -e "$STATE" ] || { echo 'failed delivery consumed dedup state' >&2; exit 1; }; }

# Not delivered: the alert stays pending (dedup state untouched).
for OUTCOME in not-sent transport-failed direct-failed none; do
  if send; then echo "outcome $OUTCOME accepted as delivered" >&2; exit 1; fi
  assert_pending
done
[ "$(count)" = 4 ]
# Handled: a digest line, a quarantine and a possibly-sent "skipped" are final.
for OUTCOME in deferred quarantined skipped direct-sent; do
  rm -f "$STATE"
  send
  grep -q '^version=2$' "$STATE"
done
OUTCOME=sent
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
OUTCOME=transport-failed
if send; then echo 'failed escalation accepted' >&2; exit 1; fi
cmp "$STATE" "$FIXTURE/before"
OUTCOME=sent
send
! grep -q '^last_alerted_at=1$' "$STATE"

# Pull-on-touch intentionally has alerts disabled and must not consume TTL.
rm "$STATE"
GIT_DIRTY_GUARD_TG_ALERTS=false
BEFORE=$(count)
send
assert_pending
[ "$(count)" = "$BEFORE" ]
echo 'delivery outcome, migration, escalation retry, silent inspection: OK'
