#!/usr/bin/env bash
# End-to-end acceptance for WP-561 Ф33 (criteria K1-K3, peer session
# 2026-11-10-06-wp561-intent-gate-review): the REAL intent-gate.sh and
# ledger-append.sh behind session-guard.sh note-file / close, with agents of
# different names in one WP. The unit-level twin of this test
# (session-guard-intent-gate-note-file-smoke.sh) runs a stub gate.
#
#   K1  two different agents claim one file in one WP -> the later one is logged
#       as a conflict (check_rc=1).
#   K2  after the first session closes normally, a claim of its file by another
#       agent is NOT a conflict.
#   K3  a session removed without close leaves its intent open: another agent's
#       claim is still a conflict. How long: check reads the ledger of today and
#       yesterday (UTC), so an intent declared yesterday still blocks and one
#       declared two days ago does not -- the open intent lives until the end of
#       the UTC day after its declaration (24-48 h).
#
# Everything lives in mktemp; the real ledger and sessions are not touched.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
# The gate and the ledger writer live in the governance repository, not here.
GATE_SRC="${IWE_INTENT_GATE_SOURCE_DIR:-$HOME/IWE/DS-my-strategy/scripts}"
for f in intent-gate.sh ledger-append.sh lib/ledger-path.sh; do
  [ -f "$GATE_SRC/$f" ] || { echo "FAIL: $GATE_SRC/$f not found (set IWE_INTENT_GATE_SOURCE_DIR)"; exit 1; }
done

B=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-intent-two-agents.XXXXXX")
trap 'rm -rf "$B"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

REPO="$B/DS-strategy"
ORIGIN="$B/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/inbox/WP-484" "$REPO/scripts" "$REPO/machine/ledger/day"
printf '%s\n' 'hypothesis_relation: "tests"' > "$REPO/inbox/WP-484/WP-484.md"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
# The fixture ledger is written in place by every open/claim; keep it out of the
# tree so a second --isolate open does not see a dirty checkout.
printf '%s\n' 'open-sessions.log' 'logs/' 'machine/' > "$REPO/.gitignore"
printf '%s\n' '#!/usr/bin/env python3' 'print("{}")' > "$REPO/scripts/process-runner.py"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'git -C "$1" push -q origin HEAD:"$2"' > "$REPO/scripts/isolate-push.sh"
printf '%s\n' '#!/usr/bin/env python3' > "$REPO/scripts/close_obligation.py"
cp "$GATE_SRC/intent-gate.sh" "$GATE_SRC/ledger-append.sh" "$REPO/scripts/"
cp -R "$GATE_SRC/lib" "$REPO/scripts/"
chmod +x "$REPO/scripts/"*.sh "$REPO/scripts/process-runner.py"
git -C "$REPO" add .
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

# Both scripts default to the live ledger; keep every write in the fixture and
# never start the real publisher.
export IWE_LEDGER_DIR="$REPO/machine/ledger"
export IWE_LEDGER_EXTERNAL_SOURCE=1
export IWE_INTENT_GATE_NOTE_FILE=warn

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

LOG="$B/.iwe-runtime/intent-gate-note-file.log"

guard() {  # guard <agent> <subcommand> [args...]
  local agent="$1"; shift
  (cd "$REPO" && IWE_ROOT="$B" IWE_SESSIONS_ROOT="$MC" IWE_GOVERNANCE_REPO=DS-strategy IWE_AGENT="$agent" \
    IWE_FROZEN_CANONICAL_PATH="" CLAUDE_CODE_SESSION_ID="cccccccc-1111-2222-3333-$(printf '%012d' "$(printf '%s' "$agent" | cksum | cut -d' ' -f1)")" \
    bash "$GUARD" "$@")
}

open_session() {  # open_session <agent> <slug>; prints the semaphore path
  guard "$1" open --wp WP-484 --task fixture --slug "$2" --agent "$1" --isolate --close-path no-code-changes \
    >"$B/open-$2.out" 2>&1 || { cat "$B/open-$2.out" >&2; echo "FAIL: open $2" >&2; exit 1; }
  local sem orz
  sem=$(grep -l "^slug: $2\$" "$B"/.iwe-runtime/sessions/"$1"-*.open)
  orz=$(sed -n 's/^orz_file: //p' "$sem")
  mkdir -p "$(dirname "$MC/$orz")"
  printf '%s\n' '---' 'date: 2026-11-10' 'type: work' 'wp: WP-484' 'duration_h: 0.1' 'artifacts: []' "agent: $1" '---' \
    '' '# Fixture' '' '## Главный инсайт' 'x' '' '## Контекст' 'x' '' '## Достигнуто' 'x' '' '## Ключевые решения' 'x' > "$MC/$orz"
  git -C "$MC" add "$orz" && git -C "$MC" commit -qm "orz $2" && git -C "$MC" push -q origin HEAD:main
  printf '%s\n' "$sem"
}

claim() {  # claim <agent> <slug> <file name in MC>
  echo x >> "$MC/$3"
  (cd "$MC" && IWE_ROOT="$B" IWE_SESSIONS_ROOT="$MC" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    bash "$GUARD" note-file "$MC/$3" --agent "$1" --slug "$2") >/dev/null 2>>"$B/claims.err"
}

conflicts() {  # conflicts <agent> <file name>; rows logged as an earlier other-agent intent
  [ -f "$LOG" ] || { echo 0; return; }
  grep -c "	$1	WP-484	mc-origin:$2	check_rc=1	" "$LOG" || true
}

gate_rows() {  # gate_rows <agent> <file name>; ANY logged outcome (conflict, gate down, declare failed)
  [ -f "$LOG" ] || { echo 0; return; }
  grep -c "	$1	WP-484	mc-origin:$2	" "$LOG" || true
}

SEM_A=$(open_session agent-a sa)
SEM_B=$(open_session agent-b sb)

echo "K1. two agents, one WP, one file: the later claim is a conflict"
claim agent-a sa shared-x.md
claim agent-b sb shared-x.md
check "agent-a (first) declared and checked clean" 0 "$(gate_rows agent-a shared-x.md)"
check "agent-b (later) logged as conflict" 1 "$(conflicts agent-b shared-x.md)"

echo "K2. after agent-a closes normally, its file is free for agent-b"
claim agent-a sa shared-y.md
# agent-a drops its edits and its claims, so the session can close as
# no-code-changes; its intents stay in the intents file and must be resolved
# by close. Forgetting a claim does not touch the intents file.
rm -f "$MC/shared-x.md" "$MC/shared-y.md"
for f in shared-x.md shared-y.md; do
  (cd "$MC" && IWE_ROOT="$B" IWE_SESSIONS_ROOT="$MC" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    bash "$GUARD" note-file --forget "$f" --agent agent-a --slug sa) >/dev/null 2>>"$B/claims.err"
done
check "agent-a still has two recorded intents before close" 2 \
  "$(awk 'NF { n++ } END { print n + 0 }' "$B/.iwe-runtime/intent-gate/$(basename "$SEM_A").intents" 2>/dev/null)"
guard agent-a close --wp WP-484 --slug sa --agent agent-a >/dev/null 2>"$B/close-a.err"
check "close of agent-a succeeds" 0 "$?"
check "close_resolve: both intents of agent-a resolved" 1 \
  "$(grep -c "	agent-a	WP-484	session:$(basename "$SEM_A")	close_resolve	resolved=2 failed=0 skipped=0$" "$LOG" || true)"
claim agent-b sb shared-y.md
check "agent-b claim of agent-a's closed file is checked clean" 0 "$(gate_rows agent-b shared-y.md)"
check "...and that claim was really declared and checked" 1 \
  "$(grep -c ' agent-b mc-origin:shared-y.md$' "$B/.iwe-runtime/intent-gate/$(basename "$SEM_B").intents" || true)"

echo "K3. a session removed without close keeps its intent open"
SEM_C=$(open_session agent-c sc)
claim agent-c sc shared-z.md
# What a sweep does to a dead owner: the semaphore is renamed, close never runs.
mv "$SEM_C" "$SEM_C.orphaned-dead-interactive"
claim agent-b sb shared-z.md
check "agent-b claim of the removed session's file is still a conflict" 1 "$(conflicts agent-b shared-z.md)"
check "the removed session's intents file is left behind" yes \
  "$([ -s "$B/.iwe-runtime/intent-gate/$(basename "$SEM_C").intents" ] && echo yes || echo no)"

echo "K3 window. an open intent blocks for today and yesterday (UTC), not before"
declare_on() {  # declare_on <date> <target>: an open intent of agent-d written into that day's ledger
  local data
  data=$(python3 -c 'import json,sys; print(json.dumps({"intent_id": "intent-old-" + sys.argv[1], "wp": 484, "target": sys.argv[2], "type": "note-file", "agent": "agent-d", "declared_at": sys.argv[1] + "T12:00:00+00:00"}))' "$1" "$2")
  bash "$REPO/scripts/ledger-append.sh" day "$1" intent_declared "$data" agent-d >/dev/null 2>&1
}
YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d yesterday +%Y-%m-%d)
TWO_DAYS_AGO=$(date -u -v-2d +%Y-%m-%d 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%d)
declare_on "$YESTERDAY" "mc-origin:old-1.md"
declare_on "$TWO_DAYS_AGO" "mc-origin:old-2.md"
claim agent-b sb old-1.md
claim agent-b sb old-2.md
check "intent declared yesterday still a conflict" 1 "$(conflicts agent-b old-1.md)"
check "intent declared two days ago no longer a conflict" 0 "$(gate_rows agent-b old-2.md)"
check "...though it is in that day's ledger" 1 \
  "$(bash -c '. "$1/scripts/lib/ledger-path.sh"; ledger_read_yaml day "$2" "$IWE_LEDGER_DIR" "$1/archive/ledger"' _ "$REPO" "$TWO_DAYS_AGO" \
     | grep -c "intent_id: intent-old-$TWO_DAYS_AGO" || true)"

if [ "$FAILURES" -ne 0 ]; then
  echo "--- gate log"; cat "$LOG" 2>/dev/null
  echo "--- claim stderr"; tail -20 "$B/claims.err" 2>/dev/null
  echo "--- close-a stderr"; tail -20 "$B/close-a.err" 2>/dev/null
  echo "FAIL: $FAILURES check(s) failed"
  exit 1
fi
echo "PASS: intent gate with two agents end to end (WP-561 Ф33 K1-K3)"
