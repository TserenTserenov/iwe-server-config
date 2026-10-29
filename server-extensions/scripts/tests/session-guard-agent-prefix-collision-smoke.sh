#!/usr/bin/env bash
# session-guard-agent-prefix-collision-smoke.sh -- WP-484 Ф266: two live records of one slug, one
# written as `claude-<id>.open`, the other as `claude-code-<id>.open` (live case of WP-385, 29.10).
#   1. `claude` and `claude-code` are one agent (Ф261): lookups by either name see the family's
#      records, ownership is decided by the record's `agent:` field, not the file-name prefix, and
#      a selection that finds several records refuses and names their guard IDs (--session-id).
#   2. A record found under the other name is handled under the name it was written with, so the
#      identity checks after selection accept it (no misleading "semaphore changed" refusal).
#   3. heal by slug refuses (target ambiguous) but names each record's guard ID as the exact target.
# All artifacts live in mktemp; nothing real is touched.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-prefix.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
SEM_DIR="$TEST_ROOT/.iwe-runtime/sessions"
mkdir -p "$SEM_DIR" "$TEST_ROOT/DS-strategy"

fail() { echo "FAIL: $*" >&2; exit 1; }

record() {  # <file name> <agent> <guard id>
    printf '%s\n' "wp: WP-999" "agent: $2" "slug: shared-slug" "session_id: $3" \
        "harness_session_id: aaaaaaaa-1111-2222-3333-444444444444" "host: $(uname -n)" > "$SEM_DIR/$1"
}
record "claude-aaaa1111aaaa1111.open" claude aaaa1111aaaa1111
record "claude-code-bbbb2222bbbb2222.open" claude-code bbbb2222bbbb2222

# Runs one function of the guard in isolation (same technique as the Ф261 smoke).
guard_fn() {  # <function> <args...>
    local fn="$1"; shift
    bash -c 'SESSION_DIR="$1"; for f in _agent_family _family_record_agent list_candidates print_candidates select_semaphore; do
                 eval "$(sed -n "/^${f}()/,/^}/p" "$2")"; done; shift 2; "$@"' \
        _ "$SEM_DIR" "$GUARD" "$fn" "$@"
}

# 1. claude and claude-code are one agent (Ф261): both names list both records, each once.
for name in claude claude-code; do
    got=$(guard_fn list_candidates "$name" | sort)
    want=$(printf '%s\n' "$SEM_DIR/claude-aaaa1111aaaa1111.open" "$SEM_DIR/claude-code-bbbb2222bbbb2222.open" | sort)
    [ "$got" = "$want" ] || fail "list_candidates $name returned: $got"
done
echo "OK: both names of one agent list the family's records once each"

# 1a. Two records of one wp+slug: selection refuses and names both guard IDs.
if guard_fn select_semaphore claude WP-999 shared-slug >"$TEST_ROOT/sel.out" 2>&1; then
    fail "select_semaphore must refuse two records of one wp+slug"
fi
for id in aaaa1111aaaa1111 bbbb2222bbbb2222; do
    grep -q "session_id=$id" "$TEST_ROOT/sel.out" || { cat "$TEST_ROOT/sel.out" >&2; fail "close refusal must name guard ID $id"; }
done
grep -q -- '--session-id' "$TEST_ROOT/sel.out" || fail "close refusal must point to --session-id"
echo "OK: ambiguous close names the guard IDs and the exact selector"

# 1b. The legacy alias name still finds a record written under the canonical name.
mv "$SEM_DIR/claude-aaaa1111aaaa1111.open" "$TEST_ROOT/parked.open"
got=$(guard_fn select_semaphore claude WP-999 shared-slug) || fail "agent claude must find the claude-code record"
[ "$got" = "$SEM_DIR/claude-code-bbbb2222bbbb2222.open" ] || fail "agent claude picked: $got"
mv "$TEST_ROOT/parked.open" "$SEM_DIR/claude-aaaa1111aaaa1111.open"
echo "OK: agent claude finds the canonical claude-code record"

# 1b'. Selection under one name hands callers the name the record was written with.
got=$(guard_fn _family_record_agent "$SEM_DIR/claude-code-bbbb2222bbbb2222.open" claude)
[ "$got" = claude-code ] || fail "record written as claude-code must be handled as claude-code, got: $got"
got=$(guard_fn _family_record_agent "$SEM_DIR/claude-aaaa1111aaaa1111.open" claude-code)
[ "$got" = claude ] || fail "record written as claude must be handled as claude, got: $got"
got=$(guard_fn _family_record_agent "$SEM_DIR/claude-aaaa1111aaaa1111.open" codex)
[ "$got" = codex ] || fail "outside the family the caller's name must stay, got: $got"
echo "OK: callers adopt the record's own agent name within the family only"

# 1c. The file name is not the owner: a claude-* file of another agent is not a candidate.
printf '%s\n' "wp: WP-997" "agent: kimi" "slug: foreign" "session_id: dddd4444dddd4444" > "$SEM_DIR/claude-dddd4444dddd4444.open"
got=$(guard_fn list_candidates claude)
if grep -q dddd4444dddd4444 <<< "$got"; then fail "a record with agent: kimi must not be a claude candidate"; fi
rm -f "$SEM_DIR/claude-dddd4444dddd4444.open"
echo "OK: the record's agent field, not its file name, decides ownership"

# 1d. A record without the agent field (legacy) is still listed.
printf '%s\n' "wp: WP-998" "slug: legacy" "session_id: cccc3333cccc3333" > "$SEM_DIR/claude-cccc3333cccc3333.open"
got=$(guard_fn list_candidates claude)
grep -qx "$SEM_DIR/claude-cccc3333cccc3333.open" <<< "$got" \
    || fail "a record without agent: must stay a candidate, got: $got"
rm -f "$SEM_DIR/claude-cccc3333cccc3333.open"
echo "OK: records without the agent field are kept"

# 2. heal by the shared slug refuses and names both exact targets.
if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="" \
    bash "$GUARD" heal shared-slug --agent claude-code >"$TEST_ROOT/heal.out" 2>&1; then
    fail "heal by an ambiguous slug must be refused"
fi
grep -q 'несколькими активными семафорами' "$TEST_ROOT/heal.out" || { cat "$TEST_ROOT/heal.out" >&2; fail "heal must refuse as ambiguous"; }
for id in aaaa1111aaaa1111 bbbb2222bbbb2222; do
    grep -q "session-guard.sh heal $id" "$TEST_ROOT/heal.out" || { cat "$TEST_ROOT/heal.out" >&2; fail "heal refusal must name guard ID $id"; }
done
echo "OK: ambiguous heal names the exact guard IDs to retry with"

# 3. End to end: a session opened as claude-code is reachable by note-file and renew under the
# alias name; before Ф266 the identity check refused with "semaphore изменился после resolve".
E2E="$TEST_ROOT/e2e"
mkdir -p "$E2E/DS-strategy/inbox/WP-999"
printf '%s\n' 'hypothesis_relation: "tests"' > "$E2E/DS-strategy/inbox/WP-999/WP-999.md"
git -C "$E2E/DS-strategy" init -q
echo x > "$E2E/DS-strategy/f.txt"
e2e_guard() {
    (cd "$E2E/DS-strategy" && IWE_ROOT="$E2E" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
        CLAUDE_CODE_SESSION_ID="aaaaaaaa-1111-2222-3333-444444444444" IWE_SESSION_ID="" IWE_AGENT="" bash "$GUARD" "$@")
}
e2e_guard open --wp WP-999 --agent claude-code --slug e2e >"$TEST_ROOT/e2e-open.out" 2>&1 \
    || { cat "$TEST_ROOT/e2e-open.out" >&2; fail "e2e open must succeed"; }
e2e_guard note-file f.txt --agent claude --wp WP-999 --slug e2e >"$TEST_ROOT/e2e-nf.out" 2>&1 \
    || { cat "$TEST_ROOT/e2e-nf.out" >&2; fail "note-file under the alias name must reach the claude-code session"; }
grep -q 'Noted in scope: f.txt' "$TEST_ROOT/e2e-nf.out" || fail "note-file must record f.txt"
e2e_guard renew --agent claude --wp WP-999 --slug e2e >"$TEST_ROOT/e2e-rn.out" 2>&1 \
    || { cat "$TEST_ROOT/e2e-rn.out" >&2; fail "renew under the alias name must reach the claude-code session"; }
grep -q 'Lease RENEW: claude-code-' "$TEST_ROOT/e2e-rn.out" || fail "renew must extend the claude-code record"
echo "OK: note-file and renew under the alias reach the session written as claude-code"

echo "ALL OK"
