#!/usr/bin/env bash
# Smoke: a session age that cannot be real is reported as unknown, never as a
# number (WP-568/538, 19.11: "235651ч" = about 27 years, 16 times in one night).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../session-guard.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Load only the helper: the script itself runs its command dispatcher on source.
helper_src=$(sed -n '/^_session_age_hours() {/,/^}/p' "$GUARD")
[ -n "$helper_src" ] || fail "_session_age_hours not found in session-guard.sh"
eval "$helper_src"

check() {  # <label> <seconds> <expected output>
  local got
  got=$(_session_age_hours "$2")
  [ "$got" = "$3" ] || fail "$1: age '$2' gave '$got', expected '$3'"
}

check "under an hour"        1800        "0"
check "five hours"           18000       "5"
check "three days"           259200      "72"
check "exactly one year"     31536000    "8760"
check "27 years (the bug)"   848375000   ""
check "epoch zero fallback"  1795000000  ""
check "empty age"            ""          ""
check "not a number"         "abc"       ""

override_got=$(IWE_MAX_PLAUSIBLE_SESSION_AGE_H=48 _session_age_hours 259200)
[ -z "$override_got" ] || fail "limit 48h still accepted 72h (got '$override_got')"

# The three notices must go through the helper, not divide by 3600 themselves.
if sed -n '/^notify_zombie_escalation() {/,/^}/p;/^notify_dead_quarantine() {/,/^}/p' "$GUARD" \
    | grep -qE '/ 3600'; then
  fail "a notice still computes hours itself"
fi

echo "PASS: session-guard-implausible-age-smoke (10 checks)"
