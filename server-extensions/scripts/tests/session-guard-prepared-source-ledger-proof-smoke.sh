#!/usr/bin/env bash
# session-guard-prepared-source-ledger-proof-smoke.sh -- WP-561 Ф30 (01.10.2026).
#
# _prepared_source_set_has_publish_proof() could not recognize a legitimately
# delivered commit to an append-only day-ledger (machine/ledger/day/**/*.yaml,
# .gitattributes merge=ledger-events) once cherry-pick/rebase rewrote its OID:
# neither the whole-commit patch-id (git cherry) nor the byte-identical-file
# check matched, because another writer had appended its OWN event to the same
# file between the two publication attempts -- own's file and origin's file
# differ, but own's content is still a proper subset. Plain text/tree 3-way
# merge (which this proof deliberately never upgrades to the repo's configured
# ledger-events driver, for the same reason remote_absorbs_prepared_tree blanks
# GIT_ATTR_SOURCE) sees two independent appends at one spot as a conflict.
# Live case 2026-10-01: night-cycle-22c3f553 on tsekh-1, `close` stuck in
# PREPARED, iwe-day-open.service failed, bug-2026-10-01-prepared-source-proof-
# rejects-rewritten-hot-file-ledger-commit.md.
#
# Extracts the real function from session-guard.sh (not a copy, same technique
# as session-guard-supersession-large-blob-smoke.sh) and drives it against
# hand-built repositories. Scenarios (two cold reviews, Kimi + Codex, found four
# of these before this test existed):
#   T1 accept_parallel_append       -- own's new event already on origin under a
#                                       different commit (the incident itself); pass.
#   T2 reject_event_lost            -- own's new event genuinely missing from
#                                       origin; refuse.
#   T3 reject_base_event_dropped    -- own silently dropped a base event; refuse.
#   T4 reject_header_lost           -- own changed a non-events header field
#                                       (schema) that never reached origin; refuse
#                                       (Codex, round 3).
#   T5 reject_type_confusion        -- own's event has an unquoted YAML date,
#                                       origin's analog is the quoted string form;
#                                       refuse rather than equate them (Codex, round 3).
#   T6 reject_dirty_worktree_attribute -- the worktree's uncommitted .gitattributes
#                                       grants ledger-events to an unrelated,
#                                       never-published path; refuse (Kimi, round 3:
#                                       attribute must be read from source_head, not
#                                       the bare worktree).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-ledger-proof.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
fail_test() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "ok   $1"; }

# Same extraction state machine as session-guard-supersession-large-blob-smoke.sh:
# bare `}` lines inside the <<'PY' heredoc are not the function's end.
extract_fn() {  # <function-name>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { active = 1 }
    active {
      print
      if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
      if (inpy && $0 == "PY") { inpy = 0; next }
      if (!inpy && $0 == "}") { active = 0; exit }
    }
  ' "$GUARD"
}
FIXTURE="$TEST_ROOT/fixture.sh"
extract_fn _prepared_source_set_has_publish_proof > "$FIXTURE"
grep -q '^_prepared_source_set_has_publish_proof() {' "$FIXTURE" \
  || fail_test "fixture setup -- extraction anchor no longer matches session-guard.sh"
# shellcheck source=/dev/null
source "$FIXTURE"

LEDGER_PATH="machine/ledger/day/2026/10/day-2026-10-01.yaml"

git_c() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

write_doc() {  # <repo> <path> <schema> <events-lines...>
  local repo="$1" path="$2" schema="$3"
  shift 3
  {
    printf 'schema: %s\n' "$schema"
    printf 'scale: day\n'
    printf "period: '2026-10-01'\n"
    printf 'events:\n'
    printf '%s\n' "$@"
  } > "$repo/$path"
}

new_repo() {  # <name> -> prints bare origin path; seeds one ledger doc with event A
  local name="$1"
  local bare="$TEST_ROOT/$name-origin.git" seed="$TEST_ROOT/$name-seed"
  git init -q --bare "$bare"
  git clone -q "$bare" "$seed"
  git -C "$seed" config user.email test@example.com
  git -C "$seed" config user.name test
  mkdir -p "$seed/$(dirname "$LEDGER_PATH")"
  printf '%s\n' 'machine/ledger/**/*.yaml merge=ledger-events' > "$seed/.gitattributes"
  write_doc "$seed" "$LEDGER_PATH" "ledger/v1" "- {ts: '2026-10-01T00:00:01Z', kind: A}"
  git -C "$seed" add .gitattributes "$LEDGER_PATH"
  git -C "$seed" commit -q -m seed
  git -C "$seed" push -q origin main
  echo "$bare"
}

clone_at() {  # <origin> <dest>
  git clone -q "$1" "$2"
  git -C "$2" config user.email test@example.com
  git -C "$2" config user.name test
}

commit_doc() {  # <repo> <message> -- commits whatever write_doc already wrote
  git -C "$1" commit -q -am "$2"
}

write_sem() {  # <path> <base> <head>
  printf 'close_delivery_source_base: %s\nclose_delivery_source_head: %s\nclose_delivery_source_commits: ["%s"]\n' \
    "$2" "$3" "$3" > "$1"
}

build_worktree() {  # <name> <own-origin> <own-sha> <remote-origin> -> echoes worktree path
  local name="$1"
  local wt="$TEST_ROOT/$name-wt"
  clone_at "$2" "$wt"
  git -C "$wt" fetch -q "$2" main
  git -C "$wt" checkout -q "$3"
  git -C "$wt" fetch -q "$4" main
  git -C "$wt" update-ref refs/remotes/origin/main FETCH_HEAD
  echo "$wt"
}

run_proof() {  # <semaphore> <worktree>
  _prepared_source_set_has_publish_proof "$1" "$2" >/dev/null 2>&1
}

# --- T1: accept_parallel_append -------------------------------------------
ORIGIN1=$(new_repo t1)
OWN1="$TEST_ROOT/t1-own"
clone_at "$ORIGIN1" "$OWN1"
BASE1=$(git -C "$OWN1" rev-parse HEAD)
write_doc "$OWN1" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE}"
commit_doc "$OWN1" "add E_MINE"
HEAD1=$(git -C "$OWN1" rev-parse HEAD)
OTHER1="$TEST_ROOT/t1-other"
clone_at "$ORIGIN1" "$OTHER1"
write_doc "$OTHER1" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE}" \
  "- {ts: '2026-10-01T00:00:03Z', kind: X_FOREIGN}"
commit_doc "$OTHER1" "republish E_MINE bundled with X_FOREIGN"
git -C "$OTHER1" push -q origin main
WT1=$(build_worktree t1 "$OWN1" "$HEAD1" "$OTHER1")
write_sem "$TEST_ROOT/sem1" "$BASE1" "$HEAD1"
if run_proof "$TEST_ROOT/sem1" "$WT1"; then
  ok "accept_parallel_append: own's event, delivered bundled with a foreign one, is recognized"
else
  fail_test "accept_parallel_append: a legitimately delivered append was refused"
fi

# --- T2: reject_event_lost -------------------------------------------------
ORIGIN2=$(new_repo t2)
OWN2="$TEST_ROOT/t2-own"
clone_at "$ORIGIN2" "$OWN2"
BASE2=$(git -C "$OWN2" rev-parse HEAD)
write_doc "$OWN2" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE}"
commit_doc "$OWN2" "add E_MINE"
HEAD2=$(git -C "$OWN2" rev-parse HEAD)
OTHER2="$TEST_ROOT/t2-other"
clone_at "$ORIGIN2" "$OTHER2"
write_doc "$OTHER2" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:03Z', kind: X_FOREIGN}"
commit_doc "$OTHER2" "publish only X_FOREIGN, E_MINE never arrived"
git -C "$OTHER2" push -q origin main
WT2=$(build_worktree t2 "$OWN2" "$HEAD2" "$OTHER2")
write_sem "$TEST_ROOT/sem2" "$BASE2" "$HEAD2"
if run_proof "$TEST_ROOT/sem2" "$WT2"; then
  fail_test "reject_event_lost: own's event is genuinely absent from origin but the proof passed"
else
  ok "reject_event_lost: a genuinely lost event is refused"
fi

# --- T3: reject_base_event_dropped -----------------------------------------
ORIGIN3=$(new_repo t3)
OWN3="$TEST_ROOT/t3-own"
clone_at "$ORIGIN3" "$OWN3"
BASE3=$(git -C "$OWN3" rev-parse HEAD)
write_doc "$OWN3" "$LEDGER_PATH" "ledger/v1" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE}"
commit_doc "$OWN3" "drop A, add E_MINE"
HEAD3=$(git -C "$OWN3" rev-parse HEAD)
OTHER3="$TEST_ROOT/t3-other"
clone_at "$ORIGIN3" "$OTHER3"
write_doc "$OTHER3" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE}" \
  "- {ts: '2026-10-01T00:00:03Z', kind: X_FOREIGN}"
commit_doc "$OTHER3" "republish with A, E_MINE and X_FOREIGN"
git -C "$OTHER3" push -q origin main
WT3=$(build_worktree t3 "$OWN3" "$HEAD3" "$OTHER3")
write_sem "$TEST_ROOT/sem3" "$BASE3" "$HEAD3"
if run_proof "$TEST_ROOT/sem3" "$WT3"; then
  fail_test "reject_base_event_dropped: own silently dropped a base event but the proof passed"
else
  ok "reject_base_event_dropped: a silently dropped base event is refused"
fi

# --- T4: reject_header_lost --------------------------------------------------
ORIGIN4=$(new_repo t4)
OWN4="$TEST_ROOT/t4-own"
clone_at "$ORIGIN4" "$OWN4"
BASE4=$(git -C "$OWN4" rev-parse HEAD)
write_doc "$OWN4" "$LEDGER_PATH" "ledger/v2" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE}"
commit_doc "$OWN4" "bump schema to v2 and add E_MINE"
HEAD4=$(git -C "$OWN4" rev-parse HEAD)
OTHER4="$TEST_ROOT/t4-other"
clone_at "$ORIGIN4" "$OTHER4"
write_doc "$OTHER4" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE}" \
  "- {ts: '2026-10-01T00:00:03Z', kind: X_FOREIGN}"
commit_doc "$OTHER4" "republish events but keep schema v1"
git -C "$OTHER4" push -q origin main
WT4=$(build_worktree t4 "$OWN4" "$HEAD4" "$OTHER4")
write_sem "$TEST_ROOT/sem4" "$BASE4" "$HEAD4"
if run_proof "$TEST_ROOT/sem4" "$WT4"; then
  fail_test "reject_header_lost: own's schema bump never reached origin but the proof passed"
else
  ok "reject_header_lost: a lost non-events header change is refused"
fi

# --- T5: reject_type_confusion -----------------------------------------------
ORIGIN5=$(new_repo t5)
OWN5="$TEST_ROOT/t5-own"
clone_at "$ORIGIN5" "$OWN5"
BASE5=$(git -C "$OWN5" rev-parse HEAD)
write_doc "$OWN5" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE, at: 2026-10-01}"
commit_doc "$OWN5" "add E_MINE with an unquoted YAML date"
HEAD5=$(git -C "$OWN5" rev-parse HEAD)
OTHER5="$TEST_ROOT/t5-other"
clone_at "$ORIGIN5" "$OTHER5"
write_doc "$OTHER5" "$LEDGER_PATH" "ledger/v1" \
  "- {ts: '2026-10-01T00:00:01Z', kind: A}" "- {ts: '2026-10-01T00:00:02Z', kind: E_MINE, at: '2026-10-01'}"
commit_doc "$OTHER5" "republish E_MINE with the quoted-string form of the same date"
git -C "$OTHER5" push -q origin main
WT5=$(build_worktree t5 "$OWN5" "$HEAD5" "$OTHER5")
write_sem "$TEST_ROOT/sem5" "$BASE5" "$HEAD5"
if run_proof "$TEST_ROOT/sem5" "$WT5"; then
  fail_test "reject_type_confusion: own's unquoted date must not canonicalize as its quoted-string origin twin"
else
  ok "reject_type_confusion: an unquoted-date vs quoted-string event is refused, not silently equated"
fi

# --- T6: reject_dirty_worktree_attribute ------------------------------------
ORIGIN6=$(new_repo t6)
OWN6="$TEST_ROOT/t6-own"
clone_at "$ORIGIN6" "$OWN6"
BASE6=$(git -C "$OWN6" rev-parse HEAD)
mkdir -p "$OWN6/other"
printf 'never published anywhere\n' > "$OWN6/other/secret.yaml"
git -C "$OWN6" add other/secret.yaml
commit_doc "$OWN6" "add other/secret.yaml, no attribute set by this commit"
HEAD6=$(git -C "$OWN6" rev-parse HEAD)
OTHER6="$TEST_ROOT/t6-other"
clone_at "$ORIGIN6" "$OTHER6"
git -C "$OTHER6" commit -q --allow-empty -m "unrelated upstream commit"
git -C "$OTHER6" push -q origin main
WT6=$(build_worktree t6 "$OWN6" "$HEAD6" "$OTHER6")
# Attacker (or a post-checkout hook) dirties the worktree's .gitattributes,
# uncommitted, to grant ledger-events to the never-published path.
printf '%s\n' 'other/secret.yaml merge=ledger-events' >> "$WT6/.gitattributes"
write_sem "$TEST_ROOT/sem6" "$BASE6" "$HEAD6"
if run_proof "$TEST_ROOT/sem6" "$WT6"; then
  fail_test "reject_dirty_worktree_attribute: an uncommitted .gitattributes edit must not grant this proof"
else
  ok "reject_dirty_worktree_attribute: attribute is read from source_head, a dirty worktree cannot grant it"
fi

[ "$FAILURES" -eq 0 ] && { echo "PASS: all scenarios"; exit 0; }
exit 1
