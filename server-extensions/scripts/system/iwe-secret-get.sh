#!/bin/bash
# iwe-secret-get — task-scoped point-query secret broker, Mac vertical slice
# (WP-544 F6, 2026-09-01 peer-session with Kimi+Codex).
#
# Contract (agreed in the peer-session): get(exact_secret_id, capability) -> secret | denial.
# No list/dump operation exists in this interface — only exact-name lookup against
# a per-secret policy entry.
#
# HONEST BOUNDARY (full writeup: DS-my-strategy/inbox/WP-544/security-model-mac.md).
# This script does NOT protect against a fully compromised agent process running
# under the same UID as the pilot: that process can always read the underlying
# source file directly, edit the policy file, or run this script with a forged
# environment. What it DOES provide:
#   1. makes point-query the only ergonomic path — closes the actual root cause
#      of the three 2026-08/09 incidents (Neon, Railway, sudo cat), all of which
#      were accidental overfetch, not malicious exfiltration;
#   2. an audit trail for forensics (tamper-evident against accidents, not
#      against a malicious same-UID process — see security-model-mac.md);
#   3. a real human-in-the-loop gate for high/critical-tier secrets via
#      osascript — the one part of this script that is an actual security
#      boundary, not just hygiene.
#
# Usage: iwe-secret-get.sh --name VARNAME [--task TASK_ID]
set -euo pipefail

POLICY_FILE="${IWE_SECRET_POLICY_FILE:-$HOME/.config/aist/secret-policy.conf}"
AUDIT_LOG="${IWE_SECRET_AUDIT_LOG:-$HOME/.iwe/secret-broker-audit.jsonl}"
NAME_RE='^[A-Z][A-Z0-9_]{0,63}$'
TASK_RE='^[A-Za-z0-9_.:-]{0,128}$'

usage() {
  printf 'usage: iwe-secret-get.sh --name VARNAME [--task TASK_ID]\n' >&2
  exit 2
}

name=""
task_id="-"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="${2:?}"; shift 2 ;;
    --task) task_id="${2:?}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$name" ] || usage

mkdir -p "$(dirname "$AUDIT_LOG")"
touch "$AUDIT_LOG"
chmod 600 "$AUDIT_LOG" 2>/dev/null || true

audit_line() {
  # flock (via python fcntl) keeps concurrent callers from interleaving
  # partial JSON lines. This does NOT protect against a same-UID process
  # editing or truncating the file outright — see honest-boundary note above.
  local decision="$1" reason="$2" tier="$3"
  python3 - "$name" "$task_id" "$decision" "$reason" "$tier" "$AUDIT_LOG" <<'PYEOF'
import fcntl, json, sys
from datetime import datetime, timezone
secret_id, task, decision, reason, tier, path = sys.argv[1:7]
rec = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "secret_id": secret_id,
    "task_id": task,
    "decision": decision,
    "reason": reason,
    "sensitivity_tier": tier,
}
with open(path, "a", encoding="utf-8") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    fcntl.flock(f, fcntl.LOCK_UN)
PYEOF
}

[[ "$name" =~ $NAME_RE ]] || {
  audit_line "deny" "invalid_name_format" "unknown"
  printf 'iwe-secret-get: invalid variable name\n' >&2
  exit 2
}

# task_id reaches an osascript command line below (tier high/critical) — an
# unvalidated value there is an AppleScript-injection RCE (found by cold
# code review 2026-09-01: a crafted --task can run `do shell script` before
# the confirmation dialog ever renders, bypassing the one real security
# boundary this script provides).
[[ "$task_id" =~ $TASK_RE ]] || {
  audit_line "deny" "invalid_task_id_format" "unknown"
  printf 'iwe-secret-get: invalid task id\n' >&2
  exit 2
}

# Policy format: NAME=tier:source_file  (flat text, no YAML dependency for a
# single-line lookup). Missing entry = deny — conservative default, matches
# the sensitivity_tier default agreed in the peer-session.
policy_line=""
if [ -f "$POLICY_FILE" ]; then
  policy_line=$(grep -m1 "^${name}=" "$POLICY_FILE" 2>/dev/null || true)
fi
if [ -z "$policy_line" ]; then
  audit_line "deny" "no_policy_entry" "unknown"
  printf 'iwe-secret-get: %s has no policy entry (default: deny) — add one to %s\n' "$name" "$POLICY_FILE" >&2
  exit 1
fi

rest="${policy_line#*=}"
case "$rest" in
  *:*) ;;
  *)
    audit_line "deny" "malformed_policy_entry" "unknown"
    printf 'iwe-secret-get: malformed policy entry for %s (expected tier:source_file)\n' "$name" >&2
    exit 1
    ;;
esac
tier="${rest%%:*}"
source_file="${rest#*:}"
source_file="${source_file/#\~/$HOME}"

case "$tier" in
  low|medium)
    ;;
  high|critical)
    # The one real boundary in this script: a live human click. No GUI
    # session available (headless SSH, cron, CI) => deny, never silently
    # falls back to auto-allow.
    if [ -t 0 ] && command -v osascript >/dev/null 2>&1; then
      # argv, not string interpolation — name/tier/task_id are pre-validated
      # by NAME_RE/TASK_RE above, but this is the one real security boundary
      # in the whole script, so it gets defense in depth on top of the regex.
      reply=$(osascript -e 'on run argv
        set secretName to item 1 of argv
        set secretTier to item 2 of argv
        set secretTask to item 3 of argv
        display dialog "Agent requests secret: " & secretName & " (tier: " & secretTier & ", task: " & secretTask & ")" buttons {"Deny", "Allow"} default button "Deny" with title "IWE Secret Broker"
      end run' -- "$name" "$tier" "$task_id" 2>/dev/null || true)
      if ! grep -q "Allow" <<<"$reply"; then
        audit_line "deny" "pilot_declined" "$tier"
        printf 'iwe-secret-get: denied (pilot declined)\n' >&2
        exit 1
      fi
    else
      audit_line "deny" "no_interactive_confirmation_available" "$tier"
      printf 'iwe-secret-get: %s is tier %s — requires interactive pilot confirmation, none available in this session\n' "$name" "$tier" >&2
      exit 1
    fi
    ;;
  *)
    audit_line "deny" "unknown_tier_${tier}" "$tier"
    printf 'iwe-secret-get: unknown sensitivity_tier %s for %s (default: deny)\n' "$tier" "$name" >&2
    exit 1
    ;;
esac

[ -r "$source_file" ] || {
  audit_line "deny" "source_unreadable" "$tier"
  printf 'iwe-secret-get: cannot read %s\n' "$source_file" >&2
  exit 1
}

# Parsed as data (awk field split), never sourced/eval'd — same pattern as
# iwe-secret-read.sh (WP-544 D27): a malformed or hostile line cannot execute.
value=$(awk -F'=' -v key="$name" '
  $1 == key { sub(/^[^=]*=/, ""); print; found=1; exit }
  END { if (!found) exit 1 }
' "$source_file") || {
  audit_line "deny" "name_not_found_in_source" "$tier"
  printf 'iwe-secret-get: %s not found in %s\n' "$name" "$source_file" >&2
  exit 1
}

audit_line "allow" "ok" "$tier"
printf '%s\n' "$value"
