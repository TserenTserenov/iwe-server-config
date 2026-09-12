#!/bin/bash
# iwe-secret-broker-write — write-side mutation broker, first slice
# (WP-544 F6, variant M', 2026-09-08 peer-session with Kimi+Codex).
#
# Contract (agreed in the peer-session, report:
# MC-sessions:2026-09/08/2026-09-08-13-wp544-f6-broker-write/report.md):
#   invoke(operation_id, task_id, idempotency_key, note) -> committed | replayed | denial
#
# Only ONE operation exists today: canary_write (operation_id=canary_write,
# version=1) — a synthetic no-op-on-real-data probe (writes to
# public.broker_canary, no relation to any real payment business table).
# It proves the pipeline (idempotency -> quota -> atomic mutation+outbox)
# live without touching real financial data. Adding a real business
# operation is separate future work: a new SECURITY DEFINER function in a
# new migration, a new case branch here — never a parameter that lets the
# caller pick its own SQL (see migration 316 header, "allowlist" section).
#
# HONEST BOUNDARY (full design + rationale: migration 316 header, and the
# peer-session report above).
#   - `actor` here is client-declared (this script's caller), not
#     cryptographically authenticated. The only real Postgres-level identity
#     boundary today is the shared `secret_broker_writer` role — anyone who
#     can invoke this script with that role's DSN can claim any actor string.
#     Per-agent authentication needs per-agent Postgres roles or a signing
#     layer; out of scope for this first slice.
#   - Emergency stop is NOT a flag this script checks. It is the
#     `secret_broker_writer` role's LOGIN privilege / password, changeable
#     only by the DB owner (a separate, never-broker-held credential) — see
#     iwe-secret-broker-emergency-stop.sh. If that role is revoked, every
#     call here fails at connection time with a normal auth error; there is
#     no code path in this script that can work around that.
#   - Rate limiting and the mutation itself are enforced INSIDE the SQL
#     function (public.broker_canary_write, migration 316) — this script
#     only builds the call and reports the outcome, it does not re-implement
#     any of the three ArchGate-mandated guarantees client-side.
#
# Usage: iwe-secret-broker-write.sh --operation canary_write --task TASK_ID
#          --idempotency-key KEY --note "text"
set -euo pipefail

DSN_SECRET_NAME="${IWE_BROKER_WRITE_DSN_NAME:-IWE_BROKER_WRITE_DSN}"
SECRET_GET="${IWE_SECRET_GET:-$(dirname "$0")/iwe-secret-get.sh}"
AUDIT_LOG="${IWE_BROKER_WRITE_AUDIT_LOG:-$HOME/.iwe/secret-broker-write-audit.jsonl}"
TASK_RE='^[A-Za-z0-9_.:-]{1,128}$'
KEY_RE='^[A-Za-z0-9_.:-]{1,128}$'
OPERATION_RE='^[a-z][a-z0-9_]{0,63}$'

usage() {
  printf 'usage: iwe-secret-broker-write.sh --operation OP --task TASK_ID --idempotency-key KEY --note TEXT\n' >&2
  exit 2
}

operation=""
task_id=""
idempotency_key=""
note=""
while [ $# -gt 0 ]; do
  case "$1" in
    --operation) operation="${2:?}"; shift 2 ;;
    --task) task_id="${2:?}"; shift 2 ;;
    --idempotency-key) idempotency_key="${2:?}"; shift 2 ;;
    --note) note="${2:?}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$operation" ] && [ -n "$task_id" ] && [ -n "$idempotency_key" ] && [ -n "$note" ] || usage

mkdir -p "$(dirname "$AUDIT_LOG")"
touch "$AUDIT_LOG"
chmod 600 "$AUDIT_LOG" 2>/dev/null || true

audit_line() {
  # Client-side denial/error log only — mirrors iwe-secret-get.sh's pattern.
  # Successful mutations are NOT duplicated here: their record of truth is
  # public.mutation_outbox (migration 316), written atomically by the SQL
  # function itself. Logging them again here would be exactly the "two
  # separate calls" pattern the peer-session design rejected.
  local decision="$1" reason="$2"
  python3 - "$operation" "$task_id" "$decision" "$reason" "$AUDIT_LOG" <<'PYEOF'
import fcntl, json, sys
from datetime import datetime, timezone
operation, task, decision, reason, path = sys.argv[1:6]
rec = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "operation_id": operation,
    "task_id": task,
    "decision": decision,
    "reason": reason,
}
with open(path, "a", encoding="utf-8") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    fcntl.flock(f, fcntl.LOCK_UN)
PYEOF
}

[[ "$operation" =~ $OPERATION_RE ]] || { audit_line "deny" "invalid_operation_format"; printf 'iwe-secret-broker-write: invalid operation id\n' >&2; exit 2; }
[[ "$task_id" =~ $TASK_RE ]] || { audit_line "deny" "invalid_task_id_format"; printf 'iwe-secret-broker-write: invalid task id\n' >&2; exit 2; }
[[ "$idempotency_key" =~ $KEY_RE ]] || { audit_line "deny" "invalid_idempotency_key_format"; printf 'iwe-secret-broker-write: invalid idempotency key\n' >&2; exit 2; }
if [ "${#note}" -gt 500 ]; then
  audit_line "deny" "note_too_long"
  printf 'iwe-secret-broker-write: note too long (max 500 chars)\n' >&2
  exit 2
fi

# Allowlist is enforced here at the script layer too (defense in depth on
# top of the DB grant, which only exposes broker_canary_write to the
# secret_broker_writer role) -- an unknown operation must fail before any
# network call, not rely solely on "no such function" from Postgres.
case "$operation" in
  canary_write) ;;
  *)
    audit_line "deny" "unknown_operation"
    printf 'iwe-secret-broker-write: unknown operation %s (allowlist: canary_write)\n' "$operation" >&2
    exit 1
    ;;
esac

dsn=$("$SECRET_GET" --name "$DSN_SECRET_NAME" --task "$task_id") || {
  audit_line "deny" "dsn_unavailable"
  printf 'iwe-secret-broker-write: could not obtain %s from broker\n' "$DSN_SECRET_NAME" >&2
  exit 1
}

# request_digest: HMAC of the canonical request (operation, params), keyed
# on the DSN itself -- NOT a genuine anti-forgery signature (cold review
# High, 08.09): whoever holds the DSN can already call broker_canary_write
# directly with psql and bypass this script's digest computation entirely,
# so a digest keyed on anything only this script knows would be equally
# forgeable by that same holder. Keying on the DSN at least ties "can compute
# a valid digest" to the same boundary as "can call the broker at all" --
# it stops a THIRD party who knows the request shape but not the DSN from
# forging a conflicting digest, which a hardcoded literal key would not.
# Real anti-forgery needs per-agent authentication (see honest-boundary note
# in migration 316 header) -- out of scope for this first slice.
request_digest=$(printf '%s|%s|%s|%s' "$operation" "1" "$idempotency_key" "$note" \
  | python3 -c "import sys,hmac,hashlib; print(hmac.new(sys.argv[1].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())" "$dsn")

# Safe SQL-literal quoting (cold review Critical #1, 08.09): pass RAW values
# via -v and reference them as :'var' (psql's own quote_literal), not the
# earlier "'${value}'" shell-side wrapping. That manual wrapping let a single
# quote character in $note break out of the string literal and run arbitrary
# SQL as secret_broker_writer -- applies the fix to all four values, not
# just note, even though actor/key/digest are also regex-constrained above.
result=$(psql "$dsn" -X -q -A -t -v ON_ERROR_STOP=1 \
  -v actor="${task_id}" \
  -v key="${idempotency_key}" \
  -v digest="${request_digest}" \
  -v note_val="${note}" \
  -c "SELECT outcome, outbox_id, canary_id FROM public.broker_canary_write(:'actor', :'key', :'digest', :'note_val');" 2>&1) || {
  # rate_limit_exceeded / idempotency_conflict / invalid_* all surface here
  # as a non-zero psql exit with the RAISE EXCEPTION message in $result.
  reason="mutation_rejected"
  case "$result" in
    *rate_limit_exceeded*) reason="rate_limit_exceeded" ;;
    *idempotency_conflict*) reason="idempotency_conflict" ;;
  esac
  audit_line "deny" "$reason"
  printf 'iwe-secret-broker-write: %s\n' "$result" >&2
  exit 1
}

printf '%s\n' "$result"
