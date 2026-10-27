#!/usr/bin/env bash
# Regression (WP-484 Ф250, measure 3): `session-guard.sh heal <slug>`.
# Default is a dry run with no side effects. A dead owner (the four quarantine
# conditions) needs no extra word; a live owner or unsaved work needs the
# pilot's word, read ONLY from the pilot-witness log of the calling
# conversation. Foreign-host and missing semaphores are refused with a reason,
# a rerun is idempotent, and the local-release fence is not bypassed.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-heal.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)  # owner-status refuses a sessions dir behind a symlink (macOS /var)
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
REGISTRY="$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl"
WITNESS_DIR="$TEST_ROOT/.iwe-runtime/pilot-witness"
TICKET_DIR="$TEST_ROOT/.iwe-runtime/close-tickets"
OBLIGATION_DIR="$TEST_ROOT/obligations"
CARDS="$GOV/inbox/agent/tasks"
LEDGER_LOG="$TEST_ROOT/ledger.log"
OBLIGATION_LOG="$TEST_ROOT/obligation.log"
HOST=$(uname -n)
export DS_PUBLISH_DIGEST_DIR="$TEST_ROOT/notify-digest"   # never the pilot's real day-close digest
export IWE_SESSIONS_ROOT="$GOV/sessions"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$CARDS" "$SESSION_DIR" "$TICKET_DIR" "$OBLIGATION_DIR" "$TEST_ROOT/bin" "$TEST_ROOT/scripts"
git -C "$GOV" init -q

cat > "$TEST_ROOT/bin/iwe-tg" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/iwe-tg"

# Stubs of the three collaborators heal calls; the real ones live in the
# governance repo and are covered by their own tests.
cat > "$GOV/scripts/process-runner.py" <<'EOF'
import glob
import os
import sys

os.environ.get("IWE_CARD_AUTOCOMMIT")  # the guard refuses runners that predate this flag
# Like the real runner (_authorize_run_caller), refuse by default: the healing
# conversation is never the card owner. Unconditional cancel is a separate mode.
if os.environ.get("STUB_RUNNER_CANCEL") != "1":
    print("owner identity: карточка Quick Close не принадлежит текущему caller", file=sys.stderr)
    sys.exit(1)
command, process_id, owner = sys.argv[1:4]
assert command == "cancel-session" and process_id == "quick-close", sys.argv
for path in glob.glob("inbox/agent/tasks/RUN-*.md"):
    with open(path, encoding="utf-8") as stream:
        text = stream.read()
    if "owner_session_id: " + owner + "\n" in text and "status: waiting" in text:
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(text.replace("status: waiting", "status: cancelled"))
EOF
cat > "$GOV/scripts/close_obligation.py" <<'EOF'
import json
import os
import sys

root = os.environ["IWE_ROOT"]
state = os.path.join(root, "obligations")
log = os.path.join(root, "obligation.log")
command = sys.argv[1]
args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
if command == "mode":
    path = os.path.join(state, args["--session-id"])
    print(open(path, encoding="utf-8").read().strip() if os.path.exists(path) else "")
elif command == "cancel":
    os.remove(os.path.join(state, args["--session-id"]))
    with open(log, "a", encoding="utf-8") as stream:
        stream.write("cancel %s %s | %s\n" % (args["--session-id"], args["--actor"], args["--reason"]))
    print(json.dumps({"status": args["--action"]}))
elif command == "void-ticket":
    runtime = os.environ.get("IWE_RUNTIME_DIR", os.path.join(root, ".iwe-runtime"))
    os.remove(os.path.join(runtime, "close-tickets", args["--nonce"] + ".json"))
    with open(log, "a", encoding="utf-8") as stream:
        stream.write("void %s\n" % args["--nonce"])
    print(json.dumps({"status": "voided"}))
else:
    sys.exit("unexpected command " + command)
EOF
cat > "$GOV/scripts/ledger-append.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LEDGER_LOG"
EOF
chmod +x "$GOV/scripts/ledger-append.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# sg <env assignments...> -- <args...>: run the guard as a caller with the given identity.
sg() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u IWE_SESSION_ID \
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_HEARTBEAT_STALE_SEC=600 \
    PATH="$TEST_ROOT/bin:$PATH" ${envs[@]+"${envs[@]}"} /bin/bash "$GUARD" "$@" 2>&1
}

write_semaphore() {  # <session> <pid> <host> [extra frontmatter lines...]
  local session="$1" pid="$2" host="$3"
  shift 3
  {
    echo "---"
    echo "agent: claude-code"
    echo "wp: WP-484"
    echo "slug: $session"
    echo "opened_at: 2000-01-01T00:00:00Z"
    echo "created_at: 2000-01-01T00:00:00Z"
    echo "session_id: $session"
    echo "harness_session_id: harness-$session"
    echo "task: fixture $session"
    echo "governance_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/$session"
    echo "isolated_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/$session"
    echo "pid: $pid"
    echo "host: $host"
    for line in "$@"; do echo "$line"; done
    echo "---"
    echo "file: inbox/WP-484/WP-484.md"
  } > "$SESSION_DIR/claude-code-$session.open"
}

write_card() {  # <run id> <owner> <slug> <status>
  cat > "$CARDS/RUN-quick-close-$1.md" <<EOF
---
kind: process-run
process_id: quick-close
run_id: RUN-quick-close-$1
owner_session_id: $2
requested_slug: $3
status: $4
---
EOF
}

write_caller_semaphore() {  # <caller harness id>: a live registered session of the calling conversation
  cat > "$SESSION_DIR/claude-code-callersem-$1.open" <<EOF
---
agent: claude-code
wp: WP-484
slug: callersem-$1
opened_at: 2000-01-01T00:00:00Z
created_at: 2000-01-01T00:00:00Z
session_id: callersem-$1
harness_session_id: $1
pid: $$
host: $HOST
---
file: inbox/WP-484/WP-484.md
EOF
}

write_witness() {  # <caller harness id> <epoch offset seconds> <text>
  mkdir -p "$WITNESS_DIR"
  python3 - "$WITNESS_DIR/$1.jsonl" "$2" "$3" <<'PY'
import datetime as dt
import json
import sys

path, offset, text = sys.argv[1:]
stamp = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=int(offset))).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"ts": stamp, "session_id": "x", "text": text}, ensure_ascii=False) + "\n")
PY
}

state_snapshot() {
  { find "$TEST_ROOT/.iwe-runtime" "$GOV" "$OBLIGATION_DIR" -path "$GOV/.git" -prune -o -print | sort
    find "$TEST_ROOT/.iwe-runtime" "$GOV" "$OBLIGATION_DIR" -path "$GOV/.git" -prune -o -type f -print | sort | xargs cksum; }
}

code_from() {  # <dry-run output> <slug>
  sed -n "s/.*heal $2 \([0-9a-f]\{6\}\)\$/\1/p" <<<"$1" | head -1
}

DEAD_PID=99999999
kill -0 "$DEAD_PID" 2>/dev/null && fail "fixture PID unexpectedly exists: $DEAD_PID"

# 1. Dry run on a dead owner: reports facts and steps, changes nothing at all.
write_semaphore dead-1 "$DEAD_PID" "$HOST"
write_card dead-1 dead-1 dead-1 waiting
write_card foreign-1 someone-else dead-1 waiting
write_card dead-1h harness-dead-1 dead-1 waiting   # owned by the harness id, not the guard id
echo "armed" > "$OBLIGATION_DIR/harness-dead-1"
echo '{"session_id": "harness-dead-1"}' > "$TICKET_DIR/nonce-dead-1.json"
BEFORE=$(state_snapshot)
OUT=$(sg -- heal dead-1)
AFTER=$(state_snapshot)
[ "$BEFORE" = "$AFTER" ] || fail "dry run changed the state: $(diff <(echo "$BEFORE") <(echo "$AFTER") | head -5)"
grep -q 'СУХОЙ ПРОГОН' <<<"$OUT" || fail "dry run banner missing: $OUT"
grep -q 'процесс: мёртв' <<<"$OUT" || fail "owner state missing: $OUT"
grep -q 'слово пилота не нужно' <<<"$OUT" || fail "dead owner should need no word: $OUT"
grep -q 'RUN-quick-close-dead-1' <<<"$OUT" || fail "own card not listed: $OUT"
grep -q 'harness-dead-1 (armed)' <<<"$OUT" || fail "obligation not listed: $OUT"
grep -q 'nonce-dead-1' <<<"$OUT" || fail "ticket not listed: $OUT"
grep -q 'Не трогаю' <<<"$OUT" && grep -q 'RUN-quick-close-foreign-1' <<<"$OUT" || fail "foreign card not reported: $OUT"
grep -q 'Боевой запуск: session-guard.sh heal dead-1 --apply --reason' <<<"$OUT" || fail "single apply command missing: $OUT"

# 2. Apply on the dead owner without any word: the semaphore goes to the same
#    quarantine as audit --quarantine-dead-interactive, the own card, the
#    obligation and the ticket are closed, the foreign card is untouched, the
#    action is in the registry and the ledger with actor and reason.
OUT=$(sg STUB_RUNNER_CANCEL=1 -- heal dead-1 --apply --reason "fixture: owner died") || fail "dead-owner apply failed: $OUT"
[ ! -e "$SESSION_DIR/claude-code-dead-1.open" ] || fail "semaphore still active"
[ -f "$SESSION_DIR/claude-code-dead-1.open.orphaned-dead-interactive" ] || fail "dead-owner quarantine missing: $OUT"
grep -q 'status: cancelled' "$CARDS/RUN-quick-close-dead-1.md" || fail "own card not cancelled"
grep -q 'status: cancelled' "$CARDS/RUN-quick-close-dead-1h.md" || fail "card owned by the harness id not cancelled"
grep -q '"source":"session-guard.sh heal"' "$REGISTRY" || fail "registry source is not heal: $(cat "$REGISTRY")"
grep -q 'status: waiting' "$CARDS/RUN-quick-close-foreign-1.md" || fail "foreign card was touched"
[ ! -e "$OBLIGATION_DIR/harness-dead-1" ] || fail "obligation not cancelled"
[ ! -e "$TICKET_DIR/nonce-dead-1.json" ] || fail "ticket not voided"
grep -q '"action":"quarantined"' "$REGISTRY" || fail "quarantine not recorded in the registry"
grep -q 'session_healed' "$LEDGER_LOG" && grep -q 'fixture: owner died' "$LEDGER_LOG" && grep -q '"actor": "unknown"' "$LEDGER_LOG" \
  || fail "ledger record lacks reason/actor: $(cat "$LEDGER_LOG")"
grep -q 'session-guard-heal:unknown' "$OBLIGATION_LOG" || fail "obligation cancel lacks the heal actor"

# 3. A rerun is idempotent: nothing active, nothing left, success.
OUT=$(sg -- heal dead-1) || fail "dry-run rerun failed: $OUT"
grep -q 'уже в карантине' <<<"$OUT" || fail "rerun does not recognise the quarantine: $OUT"
OUT=$(sg -- heal dead-1 --apply --reason "rerun") || fail "apply rerun failed: $OUT"
grep -q 'готово' <<<"$OUT" || fail "rerun is not a clean success: $OUT"

# 4. Live owner: the dry run asks for the word and prints the code; apply
#    without the word is refused and changes nothing.
write_semaphore live-1 "$$" "$HOST"
OUT=$(sg -- heal live-1)
grep -q 'процесс: жив' <<<"$OUT" || fail "live owner not reported: $OUT"
grep -q 'Смерть владельца доказана: нет' <<<"$OUT" || fail "live owner reported as proven dead: $OUT"
CODE=$(code_from "$OUT" live-1)
[ -n "$CODE" ] || fail "no confirmation code in the dry run: $OUT"
if OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-1 -- heal live-1 --apply --reason "no word"); then fail "live owner healed without the word"; fi
grep -q 'слова пилота нет' <<<"$OUT" || fail "refusal does not explain the missing word: $OUT"
[ -f "$SESSION_DIR/claude-code-live-1.open" ] || fail "refused heal moved the semaphore"
# The word cannot be supplied as an argument or without a conversation identity.
if OUT=$(sg -- heal live-1 --apply --reason x --confirm "$CODE"); then fail "--confirm accepted"; fi
grep -q 'неизвестный флаг' <<<"$OUT" || fail "--confirm should be an unknown flag: $OUT"
if OUT=$(sg -- heal live-1 --apply --reason x); then fail "healed with no conversation identity"; fi
grep -q 'нет собственной идентичности' <<<"$OUT" || fail "missing-identity refusal absent: $OUT"

# 5. Witness lines that must NOT count.
write_caller_semaphore caller-1
write_witness caller-1 -20 "разберись с зависшей сессией live-1"              # an ordinary earlier pilot message
write_witness caller-1 -10 "пожалуйста heal live-1 $CODE"                 # extra words: not the whole message
write_witness caller-1 -10800 "heal live-1 $CODE"                          # outside the two-hour window
write_witness caller-1 -10 "heal other-slug $CODE"                         # another target
write_witness caller-1 -10 "heal live-1 000000"                            # wrong code
write_witness other-caller -10 "heal live-1 $CODE"                         # another conversation's log
if OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-1 -- heal live-1 --apply --reason "bad words"); then fail "a non-matching witness line healed the session"; fi
[ -f "$SESSION_DIR/claude-code-live-1.open" ] || fail "semaphore moved on a non-matching word"

# 6. The pilot's exact line in the caller's log: success by the pilot-word path.
write_witness caller-1 -5 "подтверждаю heal live-1 $CODE"
OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-1 -- heal live-1 --apply --reason "pilot confirmed") || fail "pilot-word apply failed: $OUT"
[ ! -e "$SESSION_DIR/claude-code-live-1.open" ] || fail "semaphore still active after the word"
[ -f "$SESSION_DIR/claude-code-live-1.open.orphaned-pilot-healed" ] || fail "pilot-word quarantine missing: $OUT"
grep -q 'pilot_heal:actor=unknown:word_ts=' "$REGISTRY" || fail "pilot-word heal not recorded in the registry"
grep -q 'witness=caller-1.jsonl' "$REGISTRY" || fail "registry lacks the witness file name"
grep -q 'pilot-word' "$LEDGER_LOG" && grep -q 'witness=caller-1.jsonl' "$LEDGER_LOG" || fail "ledger lacks the trust basis or witness file"

# 7. Unsaved work: even a dead owner needs --discard-unpublished and the word.
DIRTY_WT="$TEST_ROOT/.iwe-runtime/isolated-worktrees/dirty-1"
mkdir -p "$DIRTY_WT"; git -C "$DIRTY_WT" init -q
git -C "$DIRTY_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$DIRTY_WT" update-ref refs/remotes/origin/main HEAD
echo draft > "$DIRTY_WT/note.md"
write_semaphore dirty-1 "$DEAD_PID" "$HOST"
OUT=$(sg -- heal dirty-1)
grep -q 'изменённых файлов 1' <<<"$OUT" || fail "unsaved work not reported: $OUT"
grep -q 'Нужен флаг --discard-unpublished: да' <<<"$OUT" || fail "discard flag not demanded in the dry run: $OUT"
grep -q 'ТРЕБУЕТСЯ' <<<"$OUT" || fail "unsaved work should need the word: $OUT"
CODE=$(code_from "$OUT" dirty-1)
write_caller_semaphore caller-2
write_witness caller-2 -20 "что с dirty-1?"
if OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-2 -- heal dirty-1 --apply --reason r); then fail "unsaved work healed without the flag"; fi
grep -q -- '--discard-unpublished' <<<"$OUT" || fail "refusal does not name the flag: $OUT"
if OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-2 -- heal dirty-1 --apply --reason r --discard-unpublished); then fail "unsaved work healed without the word"; fi
[ -f "$SESSION_DIR/claude-code-dirty-1.open" ] || fail "semaphore moved without the word"
write_witness caller-2 -5 "heal dirty-1 $CODE"
sg CLAUDE_CODE_SESSION_ID=caller-2 -- heal dirty-1 --apply --reason r --discard-unpublished >/dev/null || fail "unsaved work with flag and word failed"
[ -f "$DIRTY_WT/note.md" ] || fail "heal deleted the unsaved copy"
[ ! -e "$SESSION_DIR/claude-code-dirty-1.open" ] || fail "dirty semaphore still active"

# 8. Another host's semaphore is refused with the host to run on.
write_semaphore far-1 "$DEAD_PID" "other-host-42"
if OUT=$(sg -- heal far-1); then fail "foreign host healed in dry run"; fi
grep -q 'other-host-42' <<<"$OUT" && grep -q 'Выполни на other-host-42' <<<"$OUT" || fail "foreign-host refusal unclear: $OUT"
if OUT=$(sg -- heal far-1 --apply --reason r); then fail "foreign host healed"; fi
[ -f "$SESSION_DIR/claude-code-far-1.open" ] || fail "foreign-host semaphore moved"

# 9. No semaphore at all: a clear error.
if OUT=$(sg -- heal nothing-here); then fail "missing slug accepted"; fi
grep -q 'нет семафора со slug' <<<"$OUT" || fail "missing-semaphore message unclear: $OUT"

# 10. A session never heals itself.
write_semaphore self-1 "$DEAD_PID" "$HOST"
if OUT=$(sg CLAUDE_CODE_SESSION_ID=harness-self-1 -- heal self-1); then fail "own session healed"; fi
grep -q 'ЭТОМУ разговору' <<<"$OUT" || fail "own-session refusal unclear: $OUT"

# 11. The runner refusing a non-owner caller (its default, like the real one):
#     the semaphore, obligation and tickets are healed, the card stays, heal
#     says so, prints the reap-orphans command, records `left` and exits 0.
write_semaphore stuck-1 "$DEAD_PID" "$HOST"
write_card stuck-1 stuck-1 stuck-1 waiting
echo "armed" > "$OBLIGATION_DIR/harness-stuck-1"
OUT=$(sg -- heal stuck-1 --apply --reason r) || fail "runner-card leftovers must not give a permanent failure: $OUT"
grep -q 'осталось: карточки раннера (снимет reap-orphans)' <<<"$OUT" || fail "leftover card not reported: $OUT"
grep -q 'process-runner.py reap-orphans quick-close' <<<"$OUT" || fail "reap-orphans command not printed: $OUT"
grep -q 'status: waiting' "$CARDS/RUN-quick-close-stuck-1.md" || fail "card state forged"
[ ! -e "$OBLIGATION_DIR/harness-stuck-1" ] || fail "obligation not cancelled while a runner card is left"
grep -q 'stuck-1' "$LEDGER_LOG" && grep -q 'карточки раннера' "$LEDGER_LOG" || fail "ledger lacks the leftover: $(tail -2 "$LEDGER_LOG")"
# A blocking leftover (a close obligation that cannot be cancelled) still exits 7.
write_semaphore stuck-2 "$DEAD_PID" "$HOST"
echo "armed" > "$OBLIGATION_DIR/harness-stuck-2"
chmod a-w "$OBLIGATION_DIR"
if OUT=$(sg -- heal stuck-2 --apply --reason r); then chmod u+w "$OBLIGATION_DIR"; fail "an obligation that stayed armed was reported as success: $OUT"; fi
chmod u+w "$OBLIGATION_DIR"
OUT=$(sg STUB_RUNNER_CANCEL=1 -- heal stuck-1 --apply --reason "second try") || fail "rerun after the runner recovered failed: $OUT"
grep -q 'status: cancelled' "$CARDS/RUN-quick-close-stuck-1.md" || fail "rerun did not finish the card"

# 12. The local-release fence is not bypassed: a retained RUN-local-release
#     receipt with no checker blocks every mutation.
write_semaphore fenced-1 "$DEAD_PID" "$HOST"
: > "$CARDS/RUN-local-release-fixture.md"
if OUT=$(sg -- heal fenced-1 --apply --reason r); then fail "heal bypassed the local-release fence"; fi
grep -q 'local result is intentionally retained' <<<"$OUT" || fail "fence refusal unclear: $OUT"
[ -f "$SESSION_DIR/claude-code-fenced-1.open" ] || fail "fenced semaphore moved"
rm -f "$CARDS/RUN-local-release-fixture.md"

# 13. The new flags are refused outside heal and --discard-unpublished needs --apply.
if OUT=$(sg -- audit --apply); then fail "--apply accepted by audit"; fi
grep -q 'применимы только к heal' <<<"$OUT" || fail "--apply scope message missing: $OUT"
if OUT=$(sg -- heal live-2 --discard-unpublished); then fail "--discard-unpublished without --apply accepted"; fi
grep -q 'только вместе с --apply' <<<"$OUT" || fail "--discard-unpublished message missing: $OUT"

# 14. Witness filters. A log whose only record is the heal command itself (a
#     headless child conversation) is refused; a caller without a live
#     semaphore of its own is refused; another conversation's log never counts.
write_semaphore live-3 "$$" "$HOST"
OUT=$(sg -- heal live-3); CODE=$(code_from "$OUT" live-3)
write_caller_semaphore caller-3
write_witness caller-3 -5 "heal live-3 $CODE"
if OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-3 -- heal live-3 --apply --reason r); then fail "a single-record log healed"; fi
grep -q 'нет ни одной другой реплики' <<<"$OUT" || fail "single-record refusal unclear: $OUT"
[ -f "$SESSION_DIR/claude-code-live-3.open" ] || fail "semaphore moved on a single-record log"
write_witness caller-4 -20 "обычная реплика"
write_witness caller-4 -5 "heal live-3 $CODE"          # a good log, but caller-4 owns no live semaphore
if OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-4 -- heal live-3 --apply --reason r); then fail "a caller without a live semaphore healed"; fi
grep -q 'нет собственного живого семафора' <<<"$OUT" || fail "no-semaphore refusal unclear: $OUT"
write_caller_semaphore caller-5                         # owns a semaphore but has no log of its own: caller-4's log must not count
if OUT=$(sg CLAUDE_CODE_SESSION_ID=caller-5 -- heal live-3 --apply --reason r); then fail "another conversation's log was accepted"; fi
grep -q 'слова пилота нет' <<<"$OUT" || fail "foreign-log refusal unclear: $OUT"
# Codex/Kimi: the word is unprovable whatever --agent says.
if OUT=$(sg CODEX_THREAD_ID=codex-1 -- heal live-3 --apply --reason r); then fail "Codex caller healed on a word"; fi
grep -q 'недоказуемо' <<<"$OUT" || fail "Codex refusal unclear: $OUT"
if OUT=$(sg IWE_AGENT=codex -- heal live-3 --apply --reason r); then fail "codex agent healed on a word"; fi
grep -q 'недоказуемо' <<<"$OUT" || fail "codex-agent refusal unclear: $OUT"
[ -f "$SESSION_DIR/claude-code-live-3.open" ] || fail "semaphore moved by a refused heal"

# 15. After a pilot-word heal the SAME fixed name opens again (the pilot-healed
#     quarantine is terminal evidence, like the dead-interactive one); an
#     unknown sibling still blocks.
HK_SEM="$SESSION_DIR/claude-code-housekeeping-day-close.open"
cat > "$HK_SEM" <<EOF
---
agent: claude-code
housekeeping: day-close
slug: day-close
session_id: housekeeping-day-close
opened_at: 2000-01-01T00:00:00Z
created_at: 2000-01-01T00:00:00Z
pid: $$
host: $HOST
---
file: archive/day-plans/DayPlan 2000-01-01.md
EOF
open_hk() {
  ( cd "$GOV" && env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u IWE_SESSION_ID IWE_ROOT="$TEST_ROOT" \
      IWE_GOVERNANCE_REPO=DS-strategy PATH="$TEST_ROOT/bin:$PATH" \
      bash "$GUARD" open --housekeeping day-close --agent claude-code --canonical-owner day-close --owner-pid $$ ) 2>&1
}
OUT=$(sg -- heal day-close); CODE=$(code_from "$OUT" day-close)
[ -n "$CODE" ] || fail "no code for the housekeeping heal: $OUT"
write_caller_semaphore caller-6
write_witness caller-6 -20 "день-закрытие завис"
write_witness caller-6 -5 "heal day-close $CODE"
sg CLAUDE_CODE_SESSION_ID=caller-6 -- heal day-close --apply --reason "fixture: stuck day close" >/dev/null || fail "housekeeping heal failed"
[ -f "$HK_SEM.orphaned-pilot-healed" ] || fail "housekeeping quarantine missing"
OUT=$(open_hk) || fail "open of the same fixed name after a pilot-word heal was refused: $OUT"
[ -f "$HK_SEM" ] || fail "the housekeeping semaphore was not recreated"
# A repeated heal of the same fixed name lands under an epoch suffix and still opens.
rm -f "$HK_SEM.lease"
OUT=$(sg -- heal day-close); CODE=$(code_from "$OUT" day-close)
write_witness caller-6 -4 "heal day-close $CODE"
sg CLAUDE_CODE_SESSION_ID=caller-6 -- heal day-close --apply --reason "second heal" >/dev/null || fail "second housekeeping heal failed"
ls "$HK_SEM".orphaned-pilot-healed-[0-9]* >/dev/null 2>&1 || fail "second heal did not use the epoch suffix"
OUT=$(open_hk) || fail "open after a repeated pilot-word heal was refused: $OUT"
rm -f "$HK_SEM" "$HK_SEM.lease"
: > "$SESSION_DIR/claude-code-housekeeping-day-close.open.mystery"
if OUT=$(open_hk); then fail "an unknown sibling must still block the open: $OUT"; fi
rm -f "$SESSION_DIR/claude-code-housekeeping-day-close.open.mystery"

# 16. Several quarantines of one slug: ambiguous, refused. Recovery receipts
#     are not candidates.
write_semaphore multi-1 "$DEAD_PID" "$HOST"
cp "$SESSION_DIR/claude-code-multi-1.open" "$SESSION_DIR/claude-code-multi-1.open.orphaned-dead-interactive"
cp "$SESSION_DIR/claude-code-multi-1.open" "$SESSION_DIR/claude-code-multi-1.open.orphaned-pilot-healed"
rm -f "$SESSION_DIR/claude-code-multi-1.open"
if OUT=$(sg -- heal multi-1); then fail "two quarantines of one slug accepted: $OUT"; fi
grep -q 'несколькими карантинами' <<<"$OUT" || fail "ambiguity refusal unclear: $OUT"
rm -f "$SESSION_DIR/claude-code-multi-1.open.orphaned-pilot-healed"
cp "$SESSION_DIR/claude-code-multi-1.open.orphaned-dead-interactive" "$SESSION_DIR/claude-code-multi-1.open.orphaned-dead-interactive.recovery-pending"
cp "$SESSION_DIR/claude-code-multi-1.open.orphaned-dead-interactive" "$SESSION_DIR/claude-code-multi-1.open.orphaned-dead-interactive.recovered"
OUT=$(sg -- heal multi-1) || fail "a recovery receipt made the quarantine ambiguous: $OUT"
grep -q 'claude-code-multi-1.open.orphaned-dead-interactive (' <<<"$OUT" || fail "the single quarantine was not chosen: $OUT"

# 17. Close tickets are read from IWE_RUNTIME_DIR like close_obligation.py does.
ALT_RUNTIME="$TEST_ROOT/alt-runtime"
mkdir -p "$ALT_RUNTIME/close-tickets"
write_semaphore alt-1 "$DEAD_PID" "$HOST"
echo '{"session_id": "harness-alt-1"}' > "$ALT_RUNTIME/close-tickets/nonce-alt-1.json"
OUT=$(sg IWE_RUNTIME_DIR="$ALT_RUNTIME" -- heal alt-1)
grep -q 'nonce-alt-1' <<<"$OUT" || fail "ticket from IWE_RUNTIME_DIR not listed: $OUT"
sg IWE_RUNTIME_DIR="$ALT_RUNTIME" -- heal alt-1 --apply --reason r >/dev/null || fail "alt-runtime heal failed"
[ ! -e "$ALT_RUNTIME/close-tickets/nonce-alt-1.json" ] || fail "ticket in IWE_RUNTIME_DIR not voided"

echo "PASS: session-guard-heal-smoke"
