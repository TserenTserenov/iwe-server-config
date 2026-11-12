#!/usr/bin/env bash
# Regression for WP-561 Ф33: the intent gate at the `note-file` claim point.
#
# IWE_INTENT_GATE_NOTE_FILE=warn turns on observation; unset/off keeps note-file
# as before. The real gate (DS-my-strategy/scripts/intent-gate.sh) is replaced
# by a stub that logs its calls and answers `check` with STUB_CHECK_RC, so only
# the wiring in session-guard.sh is under test: what is called, what reaches the
# intents file and the conflict log, that the semaphore keeps its old lines, and
# that close resolves recorded intents whatever the flag says.
# All artifacts live in mktemp; nothing real is touched.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-intent-gate.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

GATE_LOG="$TEST_ROOT/gate-calls.log"
export GATE_LOG
: > "$GATE_LOG"
write_stub_gate() {  # <governance repo>
  mkdir -p "$1/scripts"
  cat > "$1/scripts/intent-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GATE_LOG"
case "$1" in
  declare)
    if [ "${STUB_DECLARE_RC:-0}" != 0 ]; then
      printf 'ledger: waiting for lock\n\nERROR:\tledger lock held by day close\nWARN: merge driver not installed\n' >&2
      exit "$STUB_DECLARE_RC"
    fi
    echo "intent-$(wc -l < "$GATE_LOG" | tr -d ' ')" ;;
  check) exit "${STUB_CHECK_RC:-0}" ;;
  resolve) exit 0 ;;
  resolve-batch)
    # Verdict per stdin line: STUB_REFUSE="id:reason ..." refuses, STUB_SKIP_IDS
    # gives no verdict (a timed-out batch), the rest resolve; STUB_BATCH_RC exits.
    [ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
    while read -r id agent wp; do
      [ -n "$id" ] || continue
      echo "resolve-batch $id $agent $wp" >> "$GATE_LOG"
      case " ${STUB_SKIP_IDS:-} " in *" $id "*) continue ;; esac
      reason=""
      for r in ${STUB_REFUSE:-}; do [ "${r%%:*}" = "$id" ] && reason="${r#*:}"; done
      if [ -n "$reason" ]; then echo "refused $id $reason"; else echo "resolved $id"; fi
    done
    exit "${STUB_BATCH_RC:-0}" ;;
esac
EOF
  chmod +x "$1/scripts/intent-gate.sh"
}

# --- Part A: the claim point --------------------------------------------------
GOV="$TEST_ROOT/DS-strategy"
SES="$TEST_ROOT/MC-sessions"
mkdir -p "$GOV/inbox/WP-999" "$SES"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-999/WP-999.md"
for repo in "$GOV" "$SES"; do
  git -C "$repo" init -q
  git -C "$repo" config user.email test@test.local
  git -C "$repo" config user.name test
  echo seed > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -q -m seed
done
# The target names the origin repository, not the checkout directory.
git -C "$SES" remote add origin "$TEST_ROOT/sessions-origin.git"
write_stub_gate "$GOV"

guard() {  # guard <subcommand> [args...]; runs from inside the sessions checkout
  (cd "$SES" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    IWE_SESSIONS_ROOT="$SES" bash "$GUARD" "$@")
}

guard open --wp WP-999 --agent fixture --slug gate --task gate >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }
INTENTS="$TEST_ROOT/.iwe-runtime/intent-gate/$(basename "$SEM").intents"
CONFLICTS="$TEST_ROOT/.iwe-runtime/intent-gate-note-file.log"

claims() { grep -c "^file: $1\$" "$SEM" || true; }
calls() { grep -c "^$1 " "$GATE_LOG" || true; }
conflicts() { [ -f "$CONFLICTS" ] || { echo 0; return; }; grep -c "	$1	check_rc=$2	" "$CONFLICTS" || true; }
note() {  # note <file name> <mode> [check rc]; prints the exit code, stderr to $TEST_ROOT/err
  echo x > "$SES/$1"
  (export STUB_CHECK_RC="${3:-0}"
   if [ "$2" = unset ]; then unset IWE_INTENT_GATE_NOTE_FILE; else export IWE_INTENT_GATE_NOTE_FILE="$2"; fi
   guard note-file "$SES/$1" --agent fixture --slug gate >/dev/null 2>"$TEST_ROOT/err"; echo $?)
}

echo "A1. flag unset: claim as before, gate never called"
check "exit" 0 "$(note off.md unset)"
check "claim recorded" 1 "$(claims off.md)"
check "no gate call" 0 "$(wc -l < "$GATE_LOG" | tr -d ' ')"
check "no intents file" no "$([ -e "$INTENTS" ] && echo yes || echo no)"

echo "A2. unknown value: treated as off, says so"
check "exit" 0 "$(note odd.md enforce)"
check "claim recorded" 1 "$(claims odd.md)"
check "stderr names the value" 1 "$(grep -c "unknown IWE_INTENT_GATE_NOTE_FILE='enforce'" "$TEST_ROOT/err")"
check "no gate call" 0 "$(calls declare)"

echo "A3. warn, no conflict: declare + check with the origin-named target, intent recorded aside"
check "exit" 0 "$(note warn-ok.md warn 0)"
check "claim recorded" 1 "$(claims warn-ok.md)"
check "declare called with the session WP number" 1 "$(grep -c '^declare --wp 999 --target sessions-origin:warn-ok.md --type note-file --agent fixture$' "$GATE_LOG")"
check "check called with the declared intent" 1 "$(grep -c '^check --wp 999 --target sessions-origin:warn-ok.md --agent fixture --intent-id intent-' "$GATE_LOG")"
check "intent recorded in the intents file" 1 "$(grep -c '^intent-[0-9]* fixture sessions-origin:warn-ok.md$' "$INTENTS")"
check "no conflict logged" 0 "$(conflicts sessions-origin:warn-ok.md 0)"

echo "A4. repeated claim of the same path: the gate is not asked again"
before=$(calls declare)
check "exit" 0 "$(note warn-ok.md warn 0)"
check "no second declare" "$before" "$(calls declare)"

echo "A5. warn, conflict: claim recorded, conflict in the durable log"
check "exit" 0 "$(note warn-conflict.md warn 1)"
check "claim recorded" 1 "$(claims warn-conflict.md)"
check "conflict logged" 1 "$(conflicts sessions-origin:warn-conflict.md 1)"

echo "A6. warn, gate unavailable (check rc 4): claim recorded, logged with its code"
check "exit" 0 "$(note warn-down.md warn 4)"
check "claim recorded" 1 "$(claims warn-down.md)"
check "logged with rc 4" 1 "$(conflicts sessions-origin:warn-down.md 4)"

echo "A6b. warn, declare fails: claim recorded, the reason (last stderr line, tab flattened) logged"
echo x > "$SES/warn-declare.md"
(export IWE_INTENT_GATE_NOTE_FILE=warn STUB_DECLARE_RC=2
 guard note-file "$SES/warn-declare.md" --agent fixture --slug gate >/dev/null 2>"$TEST_ROOT/err"; echo $? > "$TEST_ROOT/rc")
check "exit" 0 "$(cat "$TEST_ROOT/rc")"
check "claim recorded" 1 "$(claims warn-declare.md)"
check "declare_failed logged with its reason" 1 \
  "$(grep -c "	sessions-origin:warn-declare.md	declare_failed	ERROR: ledger lock held by day close$" "$CONFLICTS" || true)"
check "no check after a failed declare" 0 "$(grep -c '^check .*warn-declare.md' "$GATE_LOG" || true)"

echo "A7. gate script missing: claim proceeds with a note"
mv "$GOV/scripts/intent-gate.sh" "$TEST_ROOT/gate.bak"
check "exit" 0 "$(note no-gate.md warn 1)"
check "claim recorded" 1 "$(claims no-gate.md)"
check "note on stderr" 1 "$(grep -c 'claimed without an intent' "$TEST_ROOT/err")"
mv "$TEST_ROOT/gate.bak" "$GOV/scripts/intent-gate.sh"

echo "A7b. the gate's own storage broken: note-file still succeeds"
mv "$TEST_ROOT/.iwe-runtime/intent-gate" "$TEST_ROOT/intent-gate.bak"
touch "$TEST_ROOT/.iwe-runtime/intent-gate"
check "exit" 0 "$(note broken-store.md warn 0)"
check "claim recorded" 1 "$(claims broken-store.md)"
rm -f "$TEST_ROOT/.iwe-runtime/intent-gate"
mv "$TEST_ROOT/intent-gate.bak" "$TEST_ROOT/.iwe-runtime/intent-gate"

echo "A7c. unknown flag value is logged where a hook-run note-file leaves a trace"
check "logged" 1 "$(grep -c '	unknown_flag	enforce$' "$CONFLICTS")"

echo "A8. the semaphore carries no gate lines"
check "no intent ids or targets in the semaphore" 0 "$(grep -c 'intent-[0-9]\|sessions-origin:' "$SEM" || true)"

# --- Part B: close resolves the session's intents ----------------------------
# Same fixture shape as session-guard-close-no-code-changes-smoke.sh: a proven
# no-code-changes session closes without a runner card.
B="$TEST_ROOT/b"
REPO="$B/DS-strategy"
ORIGIN="$B/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/inbox/WP-484" "$REPO/scripts"
printf '%s\n' 'hypothesis_relation: "tests"' > "$REPO/inbox/WP-484/WP-484.md"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
printf '%s\n' 'open-sessions.log' > "$REPO/.gitignore"
printf '%s\n' '#!/usr/bin/env python3' 'print("{}")' > "$REPO/scripts/process-runner.py"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'git -C "$1" push -q origin HEAD:"$2"' > "$REPO/scripts/isolate-push.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$REPO/scripts/ledger-append.sh"
printf '%s\n' '#!/usr/bin/env python3' > "$REPO/scripts/close_obligation.py"
write_stub_gate "$REPO"
chmod +x "$REPO/scripts/process-runner.py" "$REPO/scripts/isolate-push.sh" "$REPO/scripts/ledger-append.sh"
git -C "$REPO" add .
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main
MC="$B/MC-sessions"
git init --bare -q "$B/mc-origin.git"
git init -q -b main "$MC"
git -C "$MC" config user.email test@example.com
git -C "$MC" config user.name "Test"
git -C "$MC" remote add origin "$B/mc-origin.git"
echo sessions > "$MC/README.md"
git -C "$MC" add README.md
git -C "$MC" commit -qm init
git -C "$MC" push -q origin HEAD:main

bguard() {
  (cd "$REPO" && IWE_ROOT="$B" IWE_SESSIONS_ROOT="$MC" IWE_GOVERNANCE_REPO=DS-strategy IWE_AGENT=fixture \
    IWE_FROZEN_CANONICAL_PATH="" CLAUDE_CODE_SESSION_ID="cccccccc-1111-2222-3333-444444444444" \
    bash "$GUARD" "$@")
}
open_b() {  # <slug>; sets BSEM and commits its ORZ
  bguard open --wp WP-484 --task fixture --slug "$1" --agent fixture --isolate --close-path no-code-changes \
    >"$B/open-$1.out" 2>&1 || { cat "$B/open-$1.out"; echo "FAIL: B open $1"; exit 1; }
  BSEM=$(grep -l "^slug: $1\$" "$B"/.iwe-runtime/sessions/fixture-*.open)
  local orz
  orz=$(sed -n 's/^orz_file: //p' "$BSEM")
  mkdir -p "$(dirname "$MC/$orz")"
  printf '%s\n' '---' 'date: 2026-11-08' 'type: work' 'wp: WP-484' 'duration_h: 0.1' 'artifacts: []' 'agent: fixture' '---' \
    '' '# Fixture' '' '## Главный инсайт' 'x' '' '## Контекст' 'x' '' '## Достигнуто' 'x' '' '## Ключевые решения' 'x' > "$MC/$orz"
  git -C "$MC" add "$orz" && git -C "$MC" commit -qm "orz $1" && git -C "$MC" push -q origin HEAD:main
}

BLOG="$B/.iwe-runtime/intent-gate-note-file.log"
IGDIR="$B/.iwe-runtime/intent-gate"
mkdir -p "$IGDIR"
summary_count() {  # <session basename> <counts>
  grep -c "	session:$1	close_resolve	rc=[0-9]* dur_s=[0-9]* sources=[0-9]* $2\$" "$BLOG" || true
}

echo "B1. close with the flag unset resolves recorded intents in one batch, as their agents, and removes the file"
open_b gate-close
BINTENTS="$IGDIR/$(basename "$BSEM").intents"
printf '%s\n' 'intent-a1 fixture MC-sessions:x.md' 'intent-a2 other-agent DS-strategy:y.md' > "$BINTENTS"
: > "$GATE_LOG"
bguard close --wp WP-484 --slug gate-close --agent fixture >/dev/null 2>"$B/close.err"
check "close succeeds" 0 "$?"
check "one batch call" 1 "$(grep -c '^resolve-batch$' "$GATE_LOG")"
check "first intent sent as its agent, WP left to the declaration" 1 "$(grep -c '^resolve-batch intent-a1 fixture -$' "$GATE_LOG")"
check "second intent sent as its agent" 1 "$(grep -c '^resolve-batch intent-a2 other-agent -$' "$GATE_LOG")"
check "no per-intent resolve" 0 "$(grep -c '^resolve ' "$GATE_LOG")"
check "intents file removed" no "$([ -e "$BINTENTS" ] && echo yes || echo no)"
check "no retry file" no "$([ -e "$BINTENTS.retry" ] && echo yes || echo no)"
check "close_resolve row: 2 resolved" 1 "$(summary_count "$(basename "$BSEM")" 'resolved=2 already=0 retry=0 lapsed=0')"

echo "B2. close with the flag on and no intents at all succeeds without gate calls or a summary row"
open_b gate-close-empty
: > "$GATE_LOG"
(export IWE_INTENT_GATE_NOTE_FILE=warn; bguard close --wp WP-484 --slug gate-close-empty --agent fixture >/dev/null 2>"$B/close2.err")
check "close succeeds" 0 "$?"
check "no gate call" 0 "$(wc -l < "$GATE_LOG" | tr -d ' ')"
check "no close_resolve row" 0 "$(grep -c "session:$(basename "$BSEM")	close_resolve" "$BLOG" || true)"

echo "B3. a batch that times out keeps the unresolved intent in a retry file with its reason"
open_b gate-close-timeout
BINTENTS="$IGDIR/$(basename "$BSEM").intents"
printf '%s\n' 'intent-b1 fixture MC-sessions:z.md' 'intent-b2 fixture MC-sessions:w.md' > "$BINTENTS"
: > "$GATE_LOG"
(export STUB_SKIP_IDS=intent-b1 STUB_BATCH_RC=124; bguard close --wp WP-484 --slug gate-close-timeout --agent fixture >/dev/null 2>"$B/close3.err")
check "close succeeds" 0 "$?"
check "intents file removed" no "$([ -e "$BINTENTS" ] && echo yes || echo no)"
check "retry file keeps only the unresolved one" "intent-b1 fixture - 1 timeout" "$(cut -d" " -f1-5 "$BINTENTS.retry" 2>/dev/null)"
check "retry line carries when the intent was first seen" yes "$(awk '$6 ~ /^[0-9]+$/ && $6 > 1700000000 {print "yes"}' "$BINTENTS.retry" 2>/dev/null)"
check "retry_item row" 1 "$(grep -c "	retry_item	intent-b1 fixture attempts=1 reason=timeout$" "$BLOG" || true)"
check "summary counts" 1 "$(summary_count "$(basename "$BSEM")" 'resolved=1 already=0 retry=1 lapsed=0')"
RETRY_B3="$BINTENTS.retry"

echo "B4. the next close on the host retries the leftover, and refusals are sorted"
open_b gate-close-next
BINTENTS="$IGDIR/$(basename "$BSEM").intents"
printf '%s\n' 'intent-c1 fixture MC-sessions:a.md' 'intent-c2 fixture MC-sessions:b.md' 'intent-c3 fixture MC-sessions:c.md' > "$BINTENTS"
: > "$GATE_LOG"
(export STUB_REFUSE="intent-c2:owner_mismatch intent-c3:not_found"; bguard close --wp WP-484 --slug gate-close-next --agent fixture >/dev/null 2>"$B/close4.err")
check "close succeeds" 0 "$?"
check "leftover of the earlier close sent" 1 "$(grep -c '^resolve-batch intent-b1 fixture -$' "$GATE_LOG")"
check "earlier retry file removed" no "$([ -e "$RETRY_B3" ] && echo yes || echo no)"
check "owner mismatch lapses at once" 1 "$(grep -c "	lapsed	intent-c2 fixture attempts=1 reason=owner_mismatch$" "$BLOG" || true)"
check "not_found kept for one more try" "intent-c3 fixture - 1 not_found" "$(cut -d" " -f1-5 "$BINTENTS.retry" 2>/dev/null)"
RETRY_B4="$BINTENTS.retry"

echo "B5. not_found twice lapses; an orphaned intents file is picked up with an unknown WP"
open_b gate-close-third
printf '%s\n' 'intent-o1 fixture MC-sessions:o.md' > "$IGDIR/fixture-gone-session.open.intents"
: > "$GATE_LOG"
(export STUB_REFUSE="intent-c3:not_found"; bguard close --wp WP-484 --slug gate-close-third --agent fixture >/dev/null 2>"$B/close5.err")
check "close succeeds" 0 "$?"
check "not_found lapses on the second try" 1 "$(grep -c "	lapsed	intent-c3 fixture attempts=2 reason=not_found$" "$BLOG" || true)"
check "orphan sent with unknown WP" 1 "$(grep -c '^resolve-batch intent-o1 fixture -$' "$GATE_LOG")"
check "orphan file removed" no "$([ -e "$IGDIR/fixture-gone-session.open.intents" ] && echo yes || echo no)"
check "earlier retry file removed" no "$([ -e "$RETRY_B4" ] && echo yes || echo no)"

echo "B6. a leftover older than the check window lapses without a gate call"
open_b gate-close-old
printf '%s\n' 'intent-x9 fixture - 1 timeout' > "$IGDIR/fixture-old.open.intents.retry"
touch -t 202601010000 "$IGDIR/fixture-old.open.intents.retry"
# A fresh retry file whose intent was first seen long ago: age follows the intent, not the file.
printf '%s\n' 'intent-x8 fixture - 3 origin_unreachable 1700000000' > "$IGDIR/fixture-refreshed.open.intents.retry"
: > "$GATE_LOG"
bguard close --wp WP-484 --slug gate-close-old --agent fixture >/dev/null 2>"$B/close6.err"
check "close succeeds" 0 "$?"
check "not sent to the gate" 0 "$(grep -c 'intent-x9' "$GATE_LOG")"
check "lapsed with its last reason" 1 "$(grep -c "	lapsed	intent-x9 fixture attempts=1 reason=timeout$" "$BLOG" || true)"
check "rewritten retry file does not keep an old intent alive" 1 "$(grep -c "	lapsed	intent-x8 fixture attempts=3 reason=origin_unreachable$" "$BLOG" || true)"
check "not sent to the gate either" 0 "$(grep -c 'intent-x8' "$GATE_LOG")"
check "old file removed" no "$([ -e "$IGDIR/fixture-old.open.intents.retry" ] && echo yes || echo no)"

echo "B7. a lock held by a live process defers: the own intents stay for a later close"
open_b gate-close-busy
BINTENTS="$IGDIR/$(basename "$BSEM").intents"
printf '%s\n' 'intent-l1 fixture MC-sessions:l.md' > "$BINTENTS"
python3 -c 'import fcntl, sys, time; f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(20)' \
  "$IGDIR/resolve.lock" > "$B/holder.out" &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q held "$B/holder.out" 2>/dev/null && break; sleep 0.3; done
: > "$GATE_LOG"
(export INTENT_GATE_LOCK_WAIT_SEC=1; bguard close --wp WP-484 --slug gate-close-busy --agent fixture >/dev/null 2>"$B/close7.err")
check "close succeeds" 0 "$?"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
check "no gate call" 0 "$(wc -l < "$GATE_LOG" | tr -d ' ')"
check "retry_deferred row" 1 "$(grep -c "session:$(basename "$BSEM")	retry_deferred	lock busy" "$BLOG" || true)"
check "own intents kept" yes "$([ -e "$BINTENTS" ] && echo yes || echo no)"
DEFERRED="$BINTENTS"

echo "B8. once the holder is gone the lock file left behind does not block; the deferred intents resolve as an orphan"
open_b gate-close-after-holder
: > "$GATE_LOG"
bguard close --wp WP-484 --slug gate-close-after-holder --agent fixture >/dev/null 2>"$B/close8.err"
check "close succeeds" 0 "$?"
check "deferred intent resolved with unknown WP" 1 "$(grep -c '^resolve-batch intent-l1 fixture -$' "$GATE_LOG")"
check "deferred file removed" no "$([ -e "$DEFERRED" ] && echo yes || echo no)"

echo "B8b. an unreadable source is reported and kept; the rest still resolve"
open_b gate-close-unreadable
BINTENTS="$IGDIR/$(basename "$BSEM").intents"
printf '%s\n' 'intent-u1 fixture MC-sessions:u.md' > "$BINTENTS"
printf '%s\n' 'intent-u2 fixture - 1 timeout' > "$IGDIR/fixture-locked.open.intents.retry"
chmod 000 "$IGDIR/fixture-locked.open.intents.retry"
: > "$GATE_LOG"
bguard close --wp WP-484 --slug gate-close-unreadable --agent fixture >/dev/null 2>"$B/close8b.err"
check "close succeeds" 0 "$?"
check "readable intent resolved" 1 "$(grep -c '^resolve-batch intent-u1 fixture -$' "$GATE_LOG")"
check "unreadable source reported" 1 "$(grep -c "	source_unreadable	fixture-locked.open.intents.retry PermissionError$" "$BLOG" || true)"
check "unreadable source kept" yes "$([ -e "$IGDIR/fixture-locked.open.intents.retry" ] && echo yes || echo no)"
chmod 600 "$IGDIR/fixture-locked.open.intents.retry"; rm -f "$IGDIR/fixture-locked.open.intents.retry"

echo "B9. a batch that outlives the budget is killed and its intents kept for retry"
open_b gate-close-slow
BINTENTS="$IGDIR/$(basename "$BSEM").intents"
printf '%s\n' 'intent-s1 fixture MC-sessions:s.md' > "$BINTENTS"
START=$SECONDS
(export STUB_SLEEP=20 INTENT_GATE_RESOLVE_BUDGET_SEC=2; bguard close --wp WP-484 --slug gate-close-slow --agent fixture >/dev/null 2>"$B/close9.err")
check "close succeeds" 0 "$?"
check "close not held by the slow batch" yes "$([ $((SECONDS - START)) -lt 15 ] && echo yes || echo no)"
check "kept for retry as timeout" "intent-s1 fixture - 1 timeout" "$(cut -d" " -f1-5 "$BINTENTS.retry" 2>/dev/null)"
check "no taken file left behind" 0 "$(ls "$IGDIR" | grep -c '\.closing\.' || true)"

if [ "$FAILURES" -ne 0 ]; then
  echo "FAIL: $FAILURES check(s) failed"
  exit 1
fi
echo "PASS: session-guard intent gate at note-file (WP-561 Ф33)"
