#!/bin/bash
# declare-intent-mailbox-smoke.sh -- WP-561 Ф88: declare-intent.sh WP-N prints the state
# of the WP's inbound mailbox ("почта" in the pilot's words). Cases: one new entry
# (counted by the server, not the working tree), empty mailbox, governance repo not
# named, server unreachable (local copy, labelled), outside-wp (no mailbox line).
# A read failure must never print a bare "no entries"; the declaration itself must
# succeed in every case (the mailbox line is advice, not a gate).
set -uo pipefail

REAL_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REAL_SCRIPTS/declare-intent.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A scripts dir with ONLY the mailbox tool and the time limiter: the handoff reader
# is absent, so the test never touches the network or a real repository.
mkdir -p "$TMP/scripts/lib"
cp "$REAL_SCRIPTS/wp-inbox.sh" "$TMP/scripts/wp-inbox.sh"
cp "$REAL_SCRIPTS/lib/run-limited.sh" "$TMP/scripts/lib/run-limited.sh"

export IWE_RUNTIME_DIR="$TMP/runtime" IWE_SCRIPTS="$TMP/scripts" CLAUDE_CODE_SESSION_ID="mbox-smoke" IWE_AGENT="claude-code"
unset IWE_GOVERNANCE_REPO IWE_GOVERNANCE_REPO_PATH IWE_WORKSPACE

fail() { echo "FAIL: $*" >&2; exit 1; }

git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/gov" 2>/dev/null
git -C "$TMP/gov" config user.email t@example.invalid
git -C "$TMP/gov" config user.name smoke
mkdir -p "$TMP/gov/inbox/WP-91" "$TMP/gov/inbox/WP-92"
echo "# WP-91" > "$TMP/gov/inbox/WP-91/WP-91.md"
echo "# WP-92" > "$TMP/gov/inbox/WP-92/WP-92.md"
bash "$TMP/scripts/wp-inbox.sh" add --to WP-91 --from "WP-1 smoke" --pointer "x" --summary "one" --repo "$TMP/gov" >/dev/null \
  || fail "fixture: cannot add a mailbox entry"
git -C "$TMP/gov" add -A
git -C "$TMP/gov" commit -q -m fixture
git -C "$TMP/gov" push -q origin HEAD:main 2>/dev/null || fail "fixture: push to the fake origin failed"

run() { bash "$SCRIPT" "$@" 2>&1; }

# 1. one new entry, counted from the server
OUT=$(IWE_GOVERNANCE_REPO_PATH="$TMP/gov" run WP-91) || fail "declaration refused: $OUT"
echo "$OUT" | grep -q "Ящик входящих WP-91: новых записей 1 (по серверу)" || fail "one entry not reported by the server: $OUT"
echo "$OUT" | grep -q "И-1 · " || fail "entry header not listed: $OUT"

# 2. empty mailbox
OUT=$(IWE_GOVERNANCE_REPO_PATH="$TMP/gov" run WP-92) || fail "declaration refused: $OUT"
echo "$OUT" | grep -q "Ящик входящих WP-92: новых записей нет (по серверу)" || fail "empty mailbox not reported: $OUT"

# 3. governance repo not named: "не проверен", never a bare zero, declaration still succeeds
OUT=$(run WP-91) || fail "declaration refused without a governance repo: $OUT"
echo "$OUT" | grep -q "Ящик входящих WP-91: не проверен" || fail "unnamed repo must say 'не проверен': $OUT"
echo "$OUT" | grep -q "новых записей" && fail "unnamed repo must not report a count: $OUT"

# 4. server unreachable: the count comes from the local copy and says so
git -C "$TMP/gov" remote set-url origin "$TMP/no-such-origin.git"
OUT=$(IWE_GOVERNANCE_REPO_PATH="$TMP/gov" run WP-91) || fail "declaration refused when the server is down: $OUT"
echo "$OUT" | grep -q "по локальной копии, сервер не опрошен" || fail "fallback must be labelled as local: $OUT"
git -C "$TMP/gov" remote set-url origin "$TMP/origin.git"

# 5. the mailbox tool is missing: "не проверен"
OUT=$(IWE_SCRIPTS="$TMP/none" IWE_GOVERNANCE_REPO_PATH="$TMP/gov" run WP-91) || fail "declaration refused without the mailbox tool: $OUT"
echo "$OUT" | grep -q "Ящик входящих WP-91: не проверен" || fail "missing tool must say 'не проверен': $OUT"

# 6. outside-wp has no mailbox
OUT=$(IWE_GOVERNANCE_REPO_PATH="$TMP/gov" run outside-wp) || fail "outside-wp refused: $OUT"
echo "$OUT" | grep -q "Ящик входящих" && fail "outside-wp must not print a mailbox line: $OUT"

# 7. the intent is recorded in every case
[ "$(jq -r '.intent' "$IWE_RUNTIME_DIR/intent-declarations/$CLAUDE_CODE_SESSION_ID.json")" = "outside-wp" ] || fail "intent record missing"

echo "OK: declare-intent.sh reports the mailbox by the server, says 'не проверен' on failure, keeps the declaration"
