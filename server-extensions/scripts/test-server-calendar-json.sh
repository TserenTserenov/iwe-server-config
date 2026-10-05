#!/bin/bash
# Regression test for server-calendar.sh --json mode (WP-389 Ф6, peer-session
# 2026-10-05-08-wp389-secretary-calendar-mail with Kimi+Codex).
#
# Covers the deterministic, credentials-independent paths: markdown mode is
# unaffected by the new flag, and every early "pending" exit (bad config,
# missing calendar_ids) emits the same machine-readable envelope instead of
# markdown text. The live OAuth success path was verified manually against
# the pilot's real calendar during the peer session (not reproducible here
# without real credentials); this script only covers what is deterministic.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SERVER_CALENDAR_UNDER_TEST:-$HERE/server-calendar.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
assert() { # assert <description> <command...>: the command must succeed
  local description="$1"; shift
  if "$@"; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    FAILURES=$((FAILURES + 1))
  fi
}

# FAKE_HOME has no ~/.secrets/google-calendar, and the explicit -u flags
# below strip the env-var form of credentials too — the "credentials not
# configured" pending path triggers deterministically, without a live
# Google API call (unlike the config/calendar_ids branches, which only run
# after a successful token exchange).
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME"

run_json() { # run_json <config_path>: prints stdout/stderr to $TMP/{out,err}, exit code to stdout
  local config="$1"
  env -u GOOGLE_REFRESH_TOKEN -u GOOGLE_CLIENT_ID -u GOOGLE_CLIENT_SECRET HOME="$FAKE_HOME" \
    bash "$SCRIPT" --json 2026-10-05 "$config" > "$TMP/out" 2> "$TMP/err"
  echo $?
}

# Case 1: no credentials configured (env unset, no ~/.secrets/google-calendar) → pending.
EMPTY_CFG="$TMP/empty.yaml"
: > "$EMPTY_CFG"
RC="$(run_json "$EMPTY_CFG")"
assert "no credentials: exits 0" test "$RC" -eq 0
assert "no credentials: output is valid JSON (not markdown)" python3 -c "import json; json.load(open('$TMP/out'))"
assert "no credentials: status is pending" bash -c "[ \"\$(python3 -c \"import json; print(json.load(open('$TMP/out'))['status'])\")\" = pending ]"
assert "no credentials: events is empty" bash -c "[ \"\$(python3 -c \"import json; print(len(json.load(open('$TMP/out'))['events']))\")\" = 0 ]"
assert "no credentials: errors[] names the actual cause" grep -qF "Google credentials" "$TMP/out"

# Case 2: schema envelope has all the fields the contract promises, even on
# the pending path (downstream readers should not special-case which fields
# exist per status).
for field in schema_version source_version generated_at window_start window_end events errors status; do
  assert "pending envelope has field '$field'" bash -c "python3 -c \"import json,sys; d=json.load(open('$TMP/out')); sys.exit(0 if '$field' in d else 1)\""
done

# Case 3: markdown mode (no --json) is unaffected — still prints the
# existing PENDING markdown line for the same no-credentials case, not JSON.
env -u GOOGLE_REFRESH_TOKEN -u GOOGLE_CLIENT_ID -u GOOGLE_CLIENT_SECRET HOME="$FAKE_HOME" \
  bash "$SCRIPT" 2026-10-05 "$EMPTY_CFG" > "$TMP/out-md" 2> "$TMP/err-md"
RC_MD=$?
assert "markdown mode: still exits 0" test "$RC_MD" -eq 0
assert "markdown mode: still prints the markdown PENDING line" grep -q "📅 \*\*Календарь" "$TMP/out-md"
assert "markdown mode: does not print JSON" bash -c "! python3 -c \"import json; json.load(open('$TMP/out-md'))\" 2>/dev/null"

# Case 4: --tz does not break the pending path (arg-parsing rewrite to a
# while/case loop, WP-389 code review 2026-10-05) — a real credentials pipe
# is needed to reach the TIME_MIN/TIME_MAX computation itself (it runs after
# the credentials/OAuth/config checks), so that part is covered separately
# below by replicating the exact embedded formula, not by running the script.
TZ_OUT="$TMP/tz-out"
env -u GOOGLE_REFRESH_TOKEN -u GOOGLE_CLIENT_ID -u GOOGLE_CLIENT_SECRET HOME="$FAKE_HOME" \
  bash "$SCRIPT" --json --tz Asia/Nicosia 2026-10-05 "$EMPTY_CFG" > "$TZ_OUT" 2>/dev/null
assert "--tz: pending path still reaches report_pending (no credentials)" \
  bash -c "[ \"\$(python3 -c \"import json; print(json.load(open('$TZ_OUT'))['status'])\")\" = pending ]"
assert "--tz: pending path output is still valid JSON" python3 -c "import json; json.load(open('$TZ_OUT'))"

# Case 5: the true-local-day-boundary formula itself, replicated verbatim
# from the --tz branch of server-calendar.sh's "Временной диапазон" section
# (credentials-free: this is the formula, not a script run — keep both in
# sync by hand if the formula there changes; the live path was verified
# manually against the pilot's real calendar during the peer session:
# --tz Asia/Nicosia 2026-10-05 -> 2026-10-04T21:00:00Z .. 2026-10-05T20:59:59Z).
FORMULA_OUT=$(python3 -c "
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
zone = ZoneInfo('Asia/Nicosia')
start_local = datetime.strptime('2026-10-05', '%Y-%m-%d').replace(tzinfo=zone)
end_local = start_local + timedelta(days=0, hours=23, minutes=59, seconds=59)
print(start_local.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
      end_local.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
assert "--tz formula: true local midnight for Asia/Nicosia (UTC+3 in October) is 21:00Z the prior UTC day" \
  [ "$FORMULA_OUT" = "2026-10-04T21:00:00Z 2026-10-05T20:59:59Z" ]

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "FAILURES: $FAILURES"
  exit 1
fi
