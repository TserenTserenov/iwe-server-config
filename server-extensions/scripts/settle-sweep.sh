#!/usr/bin/env bash
# routing: helper  called-by=session-guard.sh(open),day-open-scaffold.sh  deterministic=true
# settle-sweep.sh -- WP-484 Ф275 step 4: let the settle service finish close
# cards whose owner is gone. One shared lease for the whole sweep, taken by the
# runner (process-runner.py settle-sweep); this wrapper only picks the caller,
# the mode and prints one line when something happened.
#
# IWE_SETTLE_MODE: apply (default) | shadow (decide and log only) | off.
# Never fatal: a close must not fail because the sweep did.
set -uo pipefail

MODE="${IWE_SETTLE_MODE:-apply}"
[ "$MODE" = "off" ] && exit 0

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
GOV="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
RUNNER="$IWE_ROOT/$GOV/scripts/process-runner.py"
[ -f "$RUNNER" ] || exit 0

HOST=$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9._\n-' '-' || echo host)
ARGS=(settle-sweep --caller "settler:${HOST:-host}")
[ "$MODE" = "shadow" ] && ARGS+=(--shadow)

# The runner finds its governance root from the working directory, so run it from there.
# SIGTERM from `timeout` is handled by the runner (it releases the lease); without
# `timeout` on the host the sweep simply runs unbounded by this wrapper.
ERR_LOG="$IWE_ROOT/.iwe-runtime/settle-sweep.err"
mkdir -p "$IWE_ROOT/.iwe-runtime" 2>/dev/null || true
RUN=(python3 "$RUNNER" "${ARGS[@]}")
command -v timeout >/dev/null 2>&1 && RUN=(timeout 120 "${RUN[@]}")
OUT=$(cd "$IWE_ROOT/$GOV" && IWE_SETTLE_LEASE_REPO="$IWE_ROOT/$GOV" "${RUN[@]}" 2>>"$ERR_LOG") || exit 0

printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
counts = data.get("counts") or {}
status = data.get("status")
if status in ("lease_error",):
    print("Сведение закрытий: аренда недоступна (lease_error), обход не выполнен")
    sys.exit(0)
interesting = {k: v for k, v in counts.items() if k in ("advanced", "advance", "needs_pilot", "error")}
if interesting:
    parts = ", ".join(f"{k}: {v}" for k, v in sorted(interesting.items()))
    mode = "тень" if data.get("shadow") else "применено"
    print(f"Сведение закрытий ({mode}): {parts}")
' 2>/dev/null || true
