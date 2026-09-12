#!/bin/bash
# iwe-secret-broker-emergency-stop — operator-side revocation for the write
# broker's DB role (WP-544 F6, variant M', consensus 2026-09-08).
#
# This is deliberately NOT callable by the broker itself: it requires
# IWE_BROKER_ADMIN_DSN, a connection string with role-admin privileges on
# `secret_broker_writer`, which is never placed in the broker's own policy
# file (scripts/system/iwe-secret-get.sh's POLICY_FILE) and never reachable
# through iwe-secret-broker-write.sh. That separation IS the "physically
# independent" property agreed in the peer session (Codex: independence
# means the stop is outside the broker's own reach, not a flag it checks
# itself) — a compromised secret_broker_writer session has no path to this
# script's credential.
#
# Usage:
#   iwe-secret-broker-emergency-stop.sh stop    # revoke LOGIN immediately
#   iwe-secret-broker-emergency-stop.sh resume  # restore LOGIN
#   iwe-secret-broker-emergency-stop.sh status
set -euo pipefail

ADMIN_DSN="${IWE_BROKER_ADMIN_DSN:-}"
ROLE="secret_broker_writer"

usage() {
  printf 'usage: iwe-secret-broker-emergency-stop.sh stop|resume|status\n' >&2
  exit 2
}

[ -n "$ADMIN_DSN" ] || {
  printf 'iwe-secret-broker-emergency-stop: IWE_BROKER_ADMIN_DSN not set -- this script requires an admin credential the broker itself never holds; set it in your own shell, not in any broker-readable policy file\n' >&2
  exit 1
}

case "${1:-}" in
  stop)
    psql "$ADMIN_DSN" -X -q -v ON_ERROR_STOP=1 -c "ALTER ROLE ${ROLE} NOLOGIN;"
    printf 'iwe-secret-broker-emergency-stop: %s revoked (NOLOGIN) -- every in-flight and new call fails at connection time from now on\n' "$ROLE"
    ;;
  resume)
    psql "$ADMIN_DSN" -X -q -v ON_ERROR_STOP=1 -c "ALTER ROLE ${ROLE} LOGIN;"
    printf 'iwe-secret-broker-emergency-stop: %s restored (LOGIN)\n' "$ROLE"
    ;;
  status)
    psql "$ADMIN_DSN" -X -q -A -t -v ON_ERROR_STOP=1 \
      -c "SELECT rolcanlogin FROM pg_roles WHERE rolname = '${ROLE}';"
    ;;
  *) usage ;;
esac
