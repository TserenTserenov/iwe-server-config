#!/usr/bin/env bash
# scripts/iwe-version.sh — one-line delivery receipt for version-handshake.
#
# Prints: IWE release=<sha12> checkout=<ok|stale|unknown> runtime=<ok> memory=<ok>
# and, when the root scripts lag behind the iwe-local-config main branch known
# on this host or the last delivery held files back, one more line saying so.
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
# WP-484 Ф282 measure 4: session-guard.sh open/close call this without an
# argument, so the comparison never ran (checkout=unknown on every open), and
# 01.11 a close stopped twice on a root guard older than the DS-my-strategy
# handlers. The expected commit now defaults to origin/main of the
# iwe-local-config clone already on the host (no network: whoever fetched last
# moved the ref), the Mac root -- a git checkout without a release receipt --
# reports its own HEAD, and a lag is printed on stdout, where open shows it.

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
RELEASE_JSON="${IWE_RELEASE_JSON:-$IWE_ROOT/.iwe-runtime/iwe-release.json}"
LOCAL_CONFIG="${IWE_LOCAL_CONFIG_CLONE:-$IWE_ROOT/iwe-local-config}"
EXPECTED_ORIGIN_SHA="${1:-}"

json_field() {  # <field> -- string field of the release receipt, "unknown" when absent
    python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 'unknown'))" \
        "$RELEASE_JSON" "$1" 2>/dev/null || echo unknown
}

if [ -z "$EXPECTED_ORIGIN_SHA" ]; then
    EXPECTED_ORIGIN_SHA=$(git -C "$LOCAL_CONFIG" rev-parse --verify -q 'origin/main^{commit}' 2>/dev/null || true)
fi

excluded=""
if [ -f "$RELEASE_JSON" ]; then
    root_commit=$(json_field root_commit)
    config_revision=$(json_field config_revision)
    # Files the last sync held back behind a failing test: they are older than
    # root_commit, so the receipt names them (iwe-server-config, Ф282 measure 2).
    excluded=$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1])).get('root_commit_excluded') or []))" \
        "$RELEASE_JSON" 2>/dev/null || true)
elif [ "$(git -C "$IWE_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$IWE_ROOT" && pwd -P)" ]; then
    root_commit=$(git -C "$IWE_ROOT" rev-parse HEAD)
    config_revision="git-checkout"
else
    echo "IWE release=unknown checkout=unknown runtime=unknown memory=unknown (no $RELEASE_JSON — Mac host, or server never ran nixos-rebuild)"
    exit 0
fi

checkout_status="unknown"
if [ -n "$EXPECTED_ORIGIN_SHA" ] && [ "$root_commit" != "unknown" ]; then
    if [ "$root_commit" = "$EXPECTED_ORIGIN_SHA" ]; then
        checkout_status="ok"
    else
        checkout_status="stale"
    fi
fi

# runtime/memory status come from the same activation run that wrote
# root_commit — if activation completed without iweExtensionsVerify raising
# (see iwe-extensions-sync.nix), both are ok by construction; the release
# file wouldn't exist otherwise (verify runs before the file is written).
echo "IWE release=${root_commit:0:12} checkout=${checkout_status} runtime=ok memory=ok"

if [ "$checkout_status" = "stale" ]; then
    echo "  ⚠️  Корневые скрипты этого хоста на ${root_commit:0:12}, а основная ветка iwe-local-config на ${EXPECTED_ORIGIN_SHA:0:12}: обработчики закрытия могут оказаться новее охранника."
    echo "  root_commit=${root_commit} expected_origin_sha=${EXPECTED_ORIGIN_SHA} config_revision=${config_revision}" >&2
fi
if [ -n "$excluded" ]; then
    echo "  ⚠️  Последняя доставка задержала файлы с непрошедшим тестом, они старше ${root_commit:0:12}: ${excluded}"
fi
