#!/usr/bin/env bash
# WP-484 Ф301 П5г: note-publication with a pull-request branch as --target-ref
# refuses with a message that names the right path (receipt on the merge commit),
# not the generic "target or close state does not permit this receipt".
# GUARD_UNDER_TEST overrides the guard (used to prove the test is red before the fix).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${GUARD_UNDER_TEST:-$ROOT/scripts/session-guard.sh}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.iwe-runtime/sessions"
SHA=$(printf 'a%.0s' $(seq 1 40))
printf -- '---\nagent: claude-code\nwp: WP-1\nslug: s1\nsession_id: aaaa1111\nguard_schema: 1\n' \
  > "$T/.iwe-runtime/sessions/claude-code-aaaa1111.open"
FAIL=0
OUT=$(IWE_ROOT="$T" IWE_AGENT=claude-code bash "$GUARD" note-publication "$SHA" \
  --repo nosuchrepo --session-id aaaa1111 --target-ref refs/heads/wp484-request 2>&1)
RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL: ветка запроса должна давать отказ"; FAIL=1; }
case "$OUT" in *"не цель доставки"*"после merge"*) ;; *) echo "FAIL: нет понятного объяснения: $OUT"; FAIL=1 ;; esac
case "$OUT" in *"does not permit this receipt"*) echo "FAIL: общий отказ вместо объяснения: $OUT"; FAIL=1 ;; esac
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else exit 1; fi
