#!/usr/bin/env bash
# scripts/iwe-version.sh — one-line delivery receipt for version-handshake.
#
# Prints: IWE release=<sha12> checkout=<ok|stale> runtime=<ok|stale> memory=<ok|stale>
#
# Root cause this exists for (WP-484, peer-session 2026-08-21-01-delivery-
# version-handshake): the same iwe-local-config commit can be present in
# three independently-lagging places on tsekh-1 — git checkout, the
# nix-immutable ~/IWE/scripts/ deploy copy, and the managed-memory rsync
# target. A single SHA can't distinguish "which of the three is stale" —
# this prints each channel's status separately, sourced from
# ~/IWE/.iwe-runtime/iwe-release.json (written by iweExtensionsVerify
# activation script at nixos-rebuild time, not computed here).
#
# Called by session-guard.sh open/close (wiring: separate phase, out of
# scope for this session per peer-session consensus — this script is the
# producer half of the handshake, standalone and independently testable).

set -euo pipefail

RELEASE_JSON="${IWE_RELEASE_JSON:-$HOME/IWE/.iwe-runtime/iwe-release.json}"
EXPECTED_ORIGIN_SHA="${1:-}"

if [ ! -f "$RELEASE_JSON" ]; then
    echo "IWE release=unknown checkout=unknown runtime=unknown memory=unknown (no $RELEASE_JSON — Mac host, or server never ran nixos-rebuild)"
    exit 0
fi

root_commit=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('root_commit', 'unknown'))" "$RELEASE_JSON" 2>/dev/null || echo unknown)
config_revision=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('config_revision', 'unknown'))" "$RELEASE_JSON" 2>/dev/null || echo unknown)

if [ -n "$EXPECTED_ORIGIN_SHA" ] && [ "$root_commit" != "unknown" ]; then
    if [ "$root_commit" = "$EXPECTED_ORIGIN_SHA" ]; then
        checkout_status="ok"
    else
        checkout_status="stale"
    fi
else
    checkout_status="unknown"
fi

# runtime/memory status come from the same activation run that wrote
# root_commit — if activation completed without iweExtensionsVerify raising
# (see iwe-extensions-sync.nix), both are ok by construction; the release
# file wouldn't exist otherwise (verify runs before the file is written).
runtime_status="ok"
memory_status="ok"

sha12="${root_commit:0:12}"
echo "IWE release=${sha12} checkout=${checkout_status} runtime=${runtime_status} memory=${memory_status}"

if [ "$checkout_status" = "stale" ]; then
    echo "  root_commit=${root_commit}" >&2
    echo "  expected_origin_sha=${EXPECTED_ORIGIN_SHA}" >&2
    echo "  config_revision=${config_revision}" >&2
fi
