#!/usr/bin/env bash
# session-guard-claude-alias-duplicate-smoke.sh -- WP-484 Ф261: `claude` and `claude-code` are ONE
# agent. Before the fix `open --agent claude` wrote `claude-<id>.open`, which neither
# session-open-gate.sh (mask `claude-code-*`) nor the native-identity re-open check (prefix of its
# own agent) could see, so one conversation ended up with two live semaphores and no way to drop
# the extra one. Covers: alias normalization, the re-open check in both directions, the hook mask,
# and `release-duplicate` (WP-484 Ф267 п.1: any conversation may release when the records prove the
# same work and nothing claimed by the target is lost; never the last copy; explicit target).
# All artifacts live in mktemp; nothing real is touched.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
HOOK="$ROOT_DIR/.claude/hooks/session-open-gate.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-claude-alias.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/DS-strategy/inbox/WP-999"
printf '%s\n' 'hypothesis_relation: "tests"' > "$TEST_ROOT/DS-strategy/inbox/WP-999/WP-999.md"
SEM_DIR="$TEST_ROOT/.iwe-runtime/sessions"

NATIVE_A="aaaaaaaa-1111-2222-3333-444444444444"
NATIVE_B="bbbbbbbb-1111-2222-3333-444444444444"

guard() {  # <native session id> <args...>
    local native="$1"; shift
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
        CLAUDE_CODE_SESSION_ID="$native" IWE_SESSION_ID="" IWE_AGENT="" bash "$GUARD" "$@"
}

fail() { echo "FAIL: $*" >&2; exit 1; }
live() { find "$SEM_DIR" -maxdepth 1 -name '*.open' 2>/dev/null | sort; }
live_count() { live | grep -c . || true; }
reset_runtime() { rm -rf "$TEST_ROOT/.iwe-runtime" "$TEST_ROOT/DS-strategy/sessions"; }

# Makes an alias-named copy of the only live semaphore: what `open --agent claude` wrote before the fix.
make_alias_copy() {  # <new guard id>
    local source new_id="$1" target
    source=$(live | head -1)
    target="$SEM_DIR/claude-$new_id.open"
    sed -e "s/^agent: .*/agent: claude/" -e "s/^session_id: .*/session_id: $new_id/" "$source" > "$target"
}

# 1. The alias is normalized: one record named claude-code-*, none named claude-<id>.
guard "$NATIVE_A" open --wp WP-999 --agent claude --slug alias-test >"$TEST_ROOT/o1.out" 2>&1 \
    || { cat "$TEST_ROOT/o1.out" >&2; fail "open --agent claude must succeed"; }
[ "$(live_count)" = 1 ] || fail "alias open must leave exactly one live semaphore, got: $(live)"
case "$(basename "$(live)")" in claude-code-*.open) : ;; *) fail "alias open must write claude-code-*.open, got $(live)" ;; esac
grep -q '^agent: claude-code$' "$(live)" || fail "record must carry agent: claude-code"
echo "OK: open --agent claude is normalized to claude-code"

# 1b. The shared lookup finds the record under either agent name (close/note-file/note-commit use it).
ALIAS_SID=$(sed -n 's/^session_id: //p' "$(live)")
for name in claude claude-code; do
    found=$(IWE_ROOT="$TEST_ROOT" bash -c 'SESSION_DIR="$1"; eval "$(sed -n "/^resolve_semaphore_by_session_id()/,/^}/p" "$2")"; resolve_semaphore_by_session_id "$3" "$4"' _ "$SEM_DIR" "$GUARD" "$name" "$ALIAS_SID") \
        || fail "lookup by --session-id with agent $name must find the record"
    [ "$found" = "$(live)" ] || fail "lookup with agent $name returned $found, expected $(live)"
done
echo "OK: --session-id lookups accept both agent names"

# 2. A second open of the same work by the same conversation is refused, alias or not.
for name in claude claude-code; do
    if guard "$NATIVE_A" open --wp WP-999 --agent "$name" --slug alias-test >"$TEST_ROOT/o2.out" 2>&1; then
        fail "second open (--agent $name) of the same conversation+work must be refused"
    fi
    grep -q 'native identity уже занята' "$TEST_ROOT/o2.out" || { cat "$TEST_ROOT/o2.out" >&2; fail "re-open refusal (--agent $name) must come from the native-identity check"; }
done
[ "$(live_count)" = 1 ] || fail "refused re-open must not create a second semaphore, got: $(live)"
echo "OK: re-open of the same conversation and work is refused under both names"

# 3. Other spellings are refused, not silently rewritten.
for name in Claude CLAUDE Claude-Code; do
    if guard "$NATIVE_B" open --wp WP-999 --agent "$name" --slug other >"$TEST_ROOT/o3.out" 2>&1; then
        fail "--agent $name must be refused"
    fi
    grep -q 'не распознано' "$TEST_ROOT/o3.out" || fail "--agent $name must say the name is not recognized"
done
echo "OK: Claude/CLAUDE/Claude-Code are refused with a hint"
reset_runtime

# 4. Reverse direction: a record written under the alias before the fix still blocks open --agent claude-code.
guard "$NATIVE_A" open --wp WP-999 --agent claude-code --slug alias-test >/dev/null 2>&1
LEGACY_SRC=$(live | head -1)
LEGACY_ID=$(sed -n 's/^session_id: //p' "$LEGACY_SRC")
mv "$LEGACY_SRC" "$SEM_DIR/claude-$LEGACY_ID.open"
sed -i.bak "s/^agent: .*/agent: claude/" "$SEM_DIR/claude-$LEGACY_ID.open"; rm -f "$SEM_DIR/claude-$LEGACY_ID.open.bak"
if guard "$NATIVE_A" open --wp WP-999 --agent claude-code --slug alias-test >"$TEST_ROOT/o4.out" 2>&1; then
    fail "open --agent claude-code must be refused while an alias-named record of the same work is live"
fi
grep -q 'native identity уже занята' "$TEST_ROOT/o4.out" || { cat "$TEST_ROOT/o4.out" >&2; fail "reverse-direction refusal must come from the native-identity check"; }
[ "$(live_count)" = 1 ] || fail "refused open must not add a semaphore, got: $(live)"
echo "OK: an alias-named record from before the fix still blocks a new open"

# 5. The hook finds both names.
hook_exit() {  # <native session id>
    printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"git commit -m x"}}' "$1" \
        | IWE_ROOT="$TEST_ROOT" IWE_AGENT="claude-code" bash "$HOOK" >/dev/null 2>&1 && echo 0 || echo $?
}
[ "$(hook_exit "$NATIVE_A")" = 0 ] || fail "hook must accept a commit when the conversation's semaphore is alias-named"
[ "$(hook_exit "$NATIVE_B")" = 2 ] || fail "hook must still block a conversation with no semaphore"
echo "OK: session-open-gate sees alias-named and claude-code-named semaphores"
reset_runtime

# 6. release-duplicate: two live copies of one work.
guard "$NATIVE_A" open --wp WP-999 --agent claude-code --slug alias-test --task "duplicate fixture" >/dev/null 2>&1
KEEP=$(live | head -1); KEEP_ID=$(sed -n 's/^session_id: //p' "$KEEP")
make_alias_copy "dupdupdup1"
[ "$(live_count)" = 2 ] || fail "fixture must hold two live copies, got: $(live)"

# 6a. Records that disagree on the task, or a target that claims what the kept copy lacks, are not duplicates.
cp "$SEM_DIR/claude-dupdupdup1.open" "$TEST_ROOT/dup1.bak"
sed -i.bak "s/^task: .*/task: 'other task'/" "$SEM_DIR/claude-dupdupdup1.open"; rm -f "$SEM_DIR/claude-dupdupdup1.open.bak"
if guard "$NATIVE_B" release-duplicate --guard-id dupdupdup1 --reason "task differs" >"$TEST_ROOT/r1a.out" 2>&1; then
    fail "a copy with another task must not be released"
fi
grep -q 'единственная живая копия' "$TEST_ROOT/r1a.out" || { cat "$TEST_ROOT/r1a.out" >&2; fail "task mismatch must leave the target without a twin"; }
cp "$TEST_ROOT/dup1.bak" "$SEM_DIR/claude-dupdupdup1.open"
printf 'file: private/only-in-target.md\n' >> "$SEM_DIR/claude-dupdupdup1.open"
if guard "$NATIVE_B" release-duplicate --guard-id dupdupdup1 --reason "extra claim" >"$TEST_ROOT/r1b.out" 2>&1; then
    fail "a target with a claim the kept copy lacks must not be released"
fi
grep -q 'работа потеряется' "$TEST_ROOT/r1b.out" || { cat "$TEST_ROOT/r1b.out" >&2; fail "extra-claim refusal must name the lost claim"; }
grep -q 'only-in-target.md' "$TEST_ROOT/r1b.out" || fail "refusal must show the lost claim"
cp "$TEST_ROOT/dup1.bak" "$SEM_DIR/claude-dupdupdup1.open"
[ "$(live_count)" = 2 ] || fail "refused releases must leave both copies"
echo "OK: release-duplicate refuses another task and a target with claims the kept copy lacks"

# 6b. A kept copy that a plain close is renaming (exclusive lock) stops the release.
KEEP_FILE=$(live | grep -v dupdupdup1 | head -1)
"$(command -v flock)" -x "$KEEP_FILE" -c 'sleep 4' &
HOLDER=$!
sleep 1
if guard "$NATIVE_B" release-duplicate --guard-id dupdupdup1 --reason "kept is busy" >"$TEST_ROOT/r1c.out" 2>&1; then
    kill "$HOLDER" 2>/dev/null || true
    fail "release must refuse while the kept copy is locked by a close"
fi
wait "$HOLDER" 2>/dev/null || true
grep -q 'замок на оставляемой копии не взят' "$TEST_ROOT/r1c.out" || { cat "$TEST_ROOT/r1c.out" >&2; fail "busy kept copy refusal must say so"; }
[ "$(live_count)" = 2 ] || fail "refused release must leave both copies"
echo "OK: a locked kept copy blocks the release"

if guard "$NATIVE_A" release-duplicate --guard-id dupdupdup1 >"$TEST_ROOT/r2.out" 2>&1; then
    fail "release-duplicate without --reason must be refused"
fi
if guard "$NATIVE_A" release-duplicate --reason "x" >"$TEST_ROOT/r2.out" 2>&1; then
    fail "release-duplicate without --guard-id must be refused"
fi
if guard "$NATIVE_A" release-duplicate --guard-id no-such-guard --reason "x" >"$TEST_ROOT/r2.out" 2>&1; then
    fail "release-duplicate of an unknown guard id must be refused"
fi
echo "OK: release-duplicate needs an explicit existing target and a reason"

guard "$NATIVE_B" release-duplicate --guard-id dupdupdup1 --reason "duplicate open" >"$TEST_ROOT/r3.out" 2>&1 \
    || { cat "$TEST_ROOT/r3.out" >&2; fail "release of a proven duplicate from another conversation must succeed"; }
[ -f "$SEM_DIR/claude-dupdupdup1.open.closed" ] || fail "released copy must become .open.closed"
[ ! -e "$SEM_DIR/claude-dupdupdup1.open" ] || fail "released copy must no longer be live"
[ "$(basename "$(live)")" = "$(basename "$KEEP")" ] || fail "the other copy must stay live, got: $(live)"
grep -q "intent.*dupdupdup1.*$NATIVE_B" "$TEST_ROOT/.iwe-runtime/duplicate-release.log" || fail "release must write an intent line with the caller"
grep -q "done.*dupdupdup1.*$NATIVE_B" "$TEST_ROOT/.iwe-runtime/duplicate-release.log" || fail "release must write a done line with the caller"
grep -q "$KEEP_ID" "$TEST_ROOT/r3.out" || fail "output must name the copy that stays"
echo "OK: a proven duplicate is released from another conversation, the other copy stays, intent and done lines are written"

if guard "$NATIVE_A" release-duplicate --guard-id "$KEEP_ID" --reason "last" >"$TEST_ROOT/r4.out" 2>&1; then
    fail "the last live copy must never be released"
fi
grep -q 'единственная живая копия' "$TEST_ROOT/r4.out" || fail "last-copy refusal must say so"
grep -q 'session-guard.sh close --agent' "$TEST_ROOT/r4.out" || fail "last-copy refusal must name the close command"
[ "$(live_count)" = 1 ] || fail "refused release of the last copy must leave it live"
echo "OK: the last live copy is never released"

# 7. Three copies: an explicit target is enough, two stay.
make_alias_copy "dupdupdup2"; make_alias_copy "dupdupdup3"
[ "$(live_count)" = 3 ] || fail "fixture must hold three live copies, got: $(live)"
guard "$NATIVE_A" release-duplicate --guard-id dupdupdup2 --reason "three copies" >/dev/null 2>&1 \
    || fail "with three copies an explicit target must be releasable"
[ "$(live_count)" = 2 ] || fail "exactly one copy must go, got: $(live)"
echo "OK: with three copies only the named one goes"

# 7b. A caller without any conversation id is only labelled, never refused for it.
make_alias_copy "nocaller01"
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
    CLAUDE_CODE_SESSION_ID="" CODEX_THREAD_ID="" IWE_SESSION_ID="" IWE_AGENT="" \
    bash "$GUARD" release-duplicate --guard-id nocaller01 --reason "no caller id" >"$TEST_ROOT/r6.out" 2>&1 \
    || { cat "$TEST_ROOT/r6.out" >&2; fail "a caller without a conversation id must still release a proven duplicate"; }
grep -q 'done.*nocaller01.*unknown-caller' "$TEST_ROOT/.iwe-runtime/duplicate-release.log" || fail "journal must label the caller unknown-caller"
echo "OK: a caller without a conversation id is journalled as unknown-caller"

# 8. A copy of another work in the same conversation does not count as "another copy".
reset_runtime
guard "$NATIVE_A" open --wp WP-999 --agent claude-code --slug work-one --task "duplicate fixture" >/dev/null 2>&1
ONLY=$(live | head -1); ONLY_ID=$(sed -n 's/^session_id: //p' "$ONLY")
make_alias_copy "otherwork1"
sed -i.bak "s/^slug: .*/slug: work-two/" "$SEM_DIR/claude-otherwork1.open"; rm -f "$SEM_DIR/claude-otherwork1.open.bak"
if guard "$NATIVE_A" release-duplicate --guard-id "$ONLY_ID" --reason "other slug" >"$TEST_ROOT/r5.out" 2>&1; then
    fail "a semaphore of different work in the same conversation must not make the target a duplicate"
fi
grep -q 'единственная живая копия' "$TEST_ROOT/r5.out" || { cat "$TEST_ROOT/r5.out" >&2; fail "refusal must say it is the only live copy"; }
echo "OK: a live semaphore with another slug is not a duplicate"

echo "PASS: claude alias, re-open check, hook mask and release-duplicate behave as designed"
