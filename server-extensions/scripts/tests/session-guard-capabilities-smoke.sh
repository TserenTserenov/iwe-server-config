#!/usr/bin/env bash
# WP-484 Ф282 measure 1: `session-guard.sh capabilities` is the probe callers use
# before passing a newer flag. It must list the optional contracts and stay
# side-effect free, so a caller can run it on every close.
set -u
SG="$(cd "$(dirname "$0")/.." && pwd)/session-guard.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sg-capabilities.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

out=$(env -u IWE_SESSIONS_ROOT -u IWE_GOVERNANCE_REPO IWE_ROOT="$ROOT" bash "$SG" capabilities); rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
for token in note-commit-source-checkout note-commit-promote-intent; do
  printf '%s\n' "$out" | grep -qx "$token" && ok "lists $token" || bad "missing $token in: $out"
done
[ -z "$(ls -A "$ROOT")" ] && ok "creates nothing under IWE_ROOT" || bad "created: $(ls -A "$ROOT")"

echo "session-guard capabilities smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
