#!/usr/bin/env bash
# session-guard-open-bare-slug-identity-smoke.sh -- WP-484 Ф204/Ф211 (18.10): a bare slug (no
# --slug passed) used to default to the WP id alone, so two different conversations working the
# same WP on the same day without --slug computed the identical journal filename and collided
# (live case: parallel claude-code/codex sessions on WP-604, 2026-10-17). `open` now suffixes the
# default slug with the native harness session id when one is available, so different
# conversations get different journal files.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-bare-slug.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/DS-strategy/inbox/WP-999"
printf '%s\n' 'hypothesis_relation: "tests"' > "$TEST_ROOT/DS-strategy/inbox/WP-999/WP-999.md"

guard() {
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
        bash "$GUARD" "$@"
}

orz_files() { find "$TEST_ROOT/DS-strategy/sessions" -name '*.md' 2>/dev/null | sort; }
reset_runtime() { rm -rf "$TEST_ROOT/.iwe-runtime" "$TEST_ROOT/DS-strategy/sessions"; }

# Two different conversations (codex), same WP, no --slug: must land on two distinct journals.
# Real CLAUDE_CODE_SESSION_ID/CODEX_THREAD_ID values are UUIDs with a random leading segment
# (e.g. "9a0e726a-951e-..."); the fixture mimics that instead of a shared English-word prefix,
# which would defeat the first-8-chars suffix the same way two UUIDs never would in practice.
CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex \
    >"$TEST_ROOT/open-a.out" 2>&1
CODEX_THREAD_ID="bbbbbbbb-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex \
    >"$TEST_ROOT/open-b.out" 2>&1
FILES_AFTER_TWO=$(orz_files)
[ "$(printf '%s\n' "$FILES_AFTER_TWO" | wc -l | tr -d ' ')" = 2 ] || {
    echo "FAIL: two different conversations on the same WP must produce two journal files, got:" >&2
    printf '%s\n' "$FILES_AFTER_TWO" >&2
    exit 1
}
echo "OK: two different conversations without --slug no longer collide on one journal file"
reset_runtime

# An explicit --slug is still honored verbatim regardless of harness identity.
CODEX_THREAD_ID="cccccccc-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex \
    --slug "explicit-slug" >"$TEST_ROOT/open-explicit.out" 2>&1
[ -n "$(orz_files | grep 'explicit-slug.md$')" ] || {
    echo "FAIL: an explicit --slug must be used verbatim, ignoring harness identity" >&2
    orz_files >&2
    exit 1
}
echo "OK: explicit --slug overrides the harness-identity suffix"
reset_runtime

# No harness identity at all (kimi "by construction") keeps the historical bare-WP fallback.
CODEX_THREAD_ID="" CLAUDE_CODE_SESSION_ID="" IWE_SESSION_ID="kimi-fixture-1" \
    guard open --wp WP-999 --agent kimi >"$TEST_ROOT/open-kimi.out" 2>&1
[ -n "$(orz_files | grep '\-WP-999\.md$')" ] || {
    echo "FAIL: a caller with no harness identity must keep the bare-WP journal name" >&2
    orz_files >&2
    exit 1
}
echo "OK: callers without a harness identity keep the unchanged bare-WP fallback"

echo "PASS: bare default slug separates conversations without breaking explicit --slug or no-identity callers"
