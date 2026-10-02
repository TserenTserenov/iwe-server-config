#!/usr/bin/env bash
# session-guard-close-hot-rebuild-smoke.sh -- WP-561 Ч3 (+ cold-review fixes).
#
# A fresh isolated close must rebuild the session's commits onto fresh
# origin/main BEFORE it writes PREPARED when a hot shared file (see
# hot_publish_cas.py) moved on origin after the session read it. Before this,
# PREPARED was written first and isolate-push then rejected the set for good,
# even when the foreign edit touched other lines of the document.
#
# Cases (disposable sandbox, real isolate-push.sh and hot_publish_cas.py):
#   other       foreign edit on ANOTHER line of the registry -> close succeeds
#               with no abandon and no manual step, origin keeps both edits,
#               the note-commit claim names the rebuilt commit.
#   same        foreign edit on the SAME line -> exit 7 naming the conflicting
#               file, PREPARED not written, the copy is back on its previous
#               tip, .open is untouched.
#   duplicate   foreign side already holds the same edit -> the rebuilt set is
#               not equivalent (commit dropped) -> exit 7, copy restored.
#   delivered   the first of two session commits was already published
#               mid-session -> it is not re-checked, only the second is rebuilt.
#   dirtydup    rebase.autostash=true (as in the live governance repo), an
#               uncommitted edit in the copy and a duplicate foreign edit ->
#               refused as not clean BEFORE any rebase; the edit survives.
#   dirtyother  same dirty copy, other-line foreign edit -> refused, the copy
#               stays on its previous tip.
#   inprogress  the copy was left mid-rebase (git rebase -x false) -> exit 7
#               with the rebase --abort hint, semaphore untouched; after a
#               manual abort the close goes through.
#   interrupt   TERM reaches the guard while its rebase runs (a git shim slows
#               the rebase down) -> the rebase is finished/aborted, the copy is
#               back on its previous tip, exit 7.
#   merge       a merge commit in the session set -> exit 7 saying so, no
#               rebase attempted.
#   casbroken   hot_publish_cas.py itself fails (not a conflict) -> exit 7
#               "проверка не отработала", no rebase attempted.
#   canon       the semaphore names the canonical checkout instead of a linked
#               copy -> exit 7, the canonical branch is neither rebased nor
#               reset.
#   abandon     after a rebuild PREPARED gets stuck (origin moved the hot file
#               again) -> close --abandon-prepared with the rebuilt SHA passes,
#               because the note-commit claims were rewritten to it.
# Mutants of session-guard.sh (one or two statements replaced) must each make
# the matching case fail, so the cases cannot pass by accident.
#
# Needs the governance scripts isolate-push.sh and hot_publish_cas.py:
# IWE_HOT_SCRIPTS_DIR or $IWE_ROOT/DS-my-strategy/scripts; skipped when absent.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_GUARD="$ROOT_DIR/session-guard.sh"
HOT_SCRIPTS_DIR="${IWE_HOT_SCRIPTS_DIR:-$(cd "$ROOT_DIR/.." && pwd)/DS-my-strategy/scripts}"
if [ ! -f "$HOT_SCRIPTS_DIR/isolate-push.sh" ] || [ ! -f "$HOT_SCRIPTS_DIR/hot_publish_cas.py" ]; then
  SKIP_MESSAGE="SKIPPED: hot-file rebuild NOT covered -- isolate-push.sh/hot_publish_cas.py not found in $HOT_SCRIPTS_DIR (set IWE_HOT_SCRIPTS_DIR)"
  echo "$SKIP_MESSAGE"
  echo "$SKIP_MESSAGE" >&2
  exit 0
fi

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-hot-rebuild.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Git shim for the interrupt case: the guard's rebase gets an exec step that
# sleeps, so the test can signal the guard while the rebase is under way.
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/git" <<EOF2
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = "--onto" ] && exec "$(command -v git)" "\$@" -x 'sleep 5'
done
exec "$(command -v git)" "\$@"
EOF2
chmod +x "$SHIM_DIR/git"

git_identity() {  # <repo>
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name Test
}

# A fixed old committer date keeps the session commit's SHA distinct from the
# cherry-picked copy isolate-push publishes: within the same second both would
# be the same object, and "already delivered" would hold for the wrong reason.
session_commit() {  # <repo> <git commit args>...
  local repo="$1"
  shift
  GIT_COMMITTER_DATE="2026-09-01T10:00:00+00:00" git -C "$repo" commit "$@"
}

edit_line() {  # <file> <old line> <new line>
  sed -i.bak "s/^$2\$/$3/" "$1"
  rm -f "$1.bak"
}

# Points the semaphore's worktree fields at <path> (the canon case).
retarget_semaphore_worktree() {  # <semaphore> <path>
  python3 - "$1" "$2" <<'PY'
import sys

path, target = sys.argv[1:]
lines = open(path, encoding="utf-8").read().split("\n")
for key in ("governance_worktree: ", "isolated_worktree: "):
    lines = [key + target if line.startswith(key) else line for line in lines]
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

# Builds one sandbox with an open isolated session that committed a change to
# line2 of the shared registry; origin then receives the foreign edit(s) given
# as "old=new" pairs. Knobs (env, default off): FIRST_COMMIT_PUBLISHED,
# DIRTY_COPY, AUTOSTASH, CAS_BROKEN, CANON_SEMAPHORE, MERGE_COMMIT,
# REBASE_IN_PROGRESS. Sets E2E GOV WT SEM SESS_SLUG ORIGIN OLD_HEAD.
build_sandbox() {  # <name> <foreign old=new>...
  local name="$1" pair orz work_sha clone base
  shift
  E2E="$TEST_ROOT/$name"
  SESS_SLUG="hot-$name"
  mkdir -p "$E2E/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$E2E/scripts/agent-status-report.sh"
  chmod +x "$E2E/scripts/agent-status-report.sh"
  ORIGIN="$E2E/origin.git"
  git init -q --bare -b main "$ORIGIN"
  GOV="$E2E/DS-strategy"
  mkdir -p "$GOV/inbox/agent/tasks" "$GOV/scripts" "$GOV/docs"
  git -C "$GOV" init -q -b main
  git_identity "$GOV"
  git -C "$GOV" remote add origin "$ORIGIN"
  printf '#!/usr/bin/env python3\nprint("{}")\n' > "$GOV/scripts/process-runner.py"
  cp "$HOT_SCRIPTS_DIR/isolate-push.sh" "$HOT_SCRIPTS_DIR/hot_publish_cas.py" "$GOV/scripts/"
  cat > "$GOV/scripts/ledger-append.sh" <<'EOF2'
#!/usr/bin/env bash
printf '%s %s\n' "$3" "$4" >> "${IWE_TEST_LEDGER_LOG:?}"
EOF2
  chmod +x "$GOV/scripts/process-runner.py" "$GOV/scripts/isolate-push.sh" "$GOV/scripts/ledger-append.sh"
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\n' > "$GOV/docs/WP-REGISTRY.md"
  printf 'note1\nnote2\nnote3\n' > "$GOV/docs/notes.md"
  git -C "$GOV" add scripts docs
  git -C "$GOV" commit -qm init
  git -C "$GOV" push -q origin main
  SESS="$E2E/MC-sessions-fixture"
  git init -q --bare -b main "$E2E/sessions-origin.git"
  git init -q -b main "$SESS"
  git_identity "$SESS"
  git -C "$SESS" remote add origin "$E2E/sessions-origin.git"
  echo placeholder > "$SESS/00-index.md"
  git -C "$SESS" add 00-index.md
  git -C "$SESS" commit -qm init
  git -C "$SESS" push -q origin main

  export IWE_ROOT="$E2E" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="fixture" \
         IWE_SESSIONS_ROOT="$SESS" IWE_FROZEN_CANONICAL_PATH="" \
         CLAUDE_CODE_SESSION_ID="hot-$name" IWE_TEST_LEDGER_LOG="$E2E/ledger.log"
  : > "$IWE_TEST_LEDGER_LOG"
  OPEN_OUT=$(cd "$GOV" && bash "$REAL_GUARD" open --wp WP-484 --task fixture --slug "$SESS_SLUG" \
    --agent fixture --isolate --force --close-path peer-session)
  WT=$(printf '%s\n' "$OPEN_OUT" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
  [ -n "$WT" ] && [ -d "$WT" ] || { echo "FAIL: setup -- open --isolate gave no worktree" >&2; exit 1; }
  SEM=$(find "$E2E/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
  orz=$(grep '^orz_file: ' "$SEM" | cut -d' ' -f2-)
  mkdir -p "$SESS/$(dirname "$orz")"
  printf -- '---\ndate: 2026-09-01\ntype: work\nwp: WP-484\nduration_h: 0.1\nartifacts: []\nagent: fixture\n---\n\n# Fixture\n\n## Главный инсайт\nx\n\n## Контекст\nx\n\n## Достигнуто\nx\n\n## Ключевые решения\nx\n' > "$SESS/$orz"
  git -C "$SESS" add "$orz"
  git -C "$SESS" commit -qm orz
  git -C "$SESS" push -q origin main

  edit_line "$WT/docs/WP-REGISTRY.md" line2 line2-session
  session_commit "$WT" -qam "session: registry line2"
  work_sha=$(git -C "$WT" rev-parse HEAD)
  OLD_HEAD="$work_sha"
  echo "commit: DS-strategy $work_sha" >> "$SEM"
  if [ "${EMPTY_COMMIT:-0}" -eq 1 ]; then
    session_commit "$WT" --allow-empty -qm "session: empty marker"
    OLD_HEAD=$(git -C "$WT" rev-parse HEAD)
    echo "commit: DS-strategy $OLD_HEAD" >> "$SEM"
  fi
  if [ "${FIRST_COMMIT_PUBLISHED:-0}" -eq 1 ]; then
    # A second commit; the first one is published mid-session, as ds-publish does.
    edit_line "$WT/docs/WP-REGISTRY.md" line6 line6-session
    session_commit "$WT" -qam "session: registry line6"
    OLD_HEAD=$(git -C "$WT" rev-parse HEAD)
    echo "commit: DS-strategy $OLD_HEAD" >> "$SEM"
    IWE_PUBLICATION_PARENT_LOCK=1 bash "$GOV/scripts/isolate-push.sh" "$WT" main \
      --exact-commit "$work_sha" >"$E2E/first-publish.out" 2>&1
  fi
  if [ "${DIRTY_COPY:-0}" -eq 1 ]; then
    echo UNCOMMITTED-WORK >> "$WT/docs/notes.md"
  fi
  if [ "${AUTOSTASH:-0}" -eq 1 ]; then
    # Repository config: the linked copy inherits it, as the live one does.
    git -C "$GOV" config rebase.autostash true
  fi
  if [ "${CAS_BROKEN:-0}" -eq 1 ]; then
    # The check fails for a reason that is not a conflict (the guard reads the
    # canonical checkout's copy of the script).
    printf '#!/usr/bin/env python3\nimport sys\nprint("git rev-list timed out after 15 seconds", file=sys.stderr)\nraise SystemExit(1)\n' \
      > "$GOV/scripts/hot_publish_cas.py"
  fi
  if [ "${CANON_SEMAPHORE:-0}" -eq 1 ]; then
    # The canonical checkout carries the session commit and the semaphore
    # (corrupted) names it as the copy to close from.
    git -C "$GOV" merge -q --ff-only "$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
    retarget_semaphore_worktree "$SEM" "$GOV"
  fi

  clone="$E2E/foreign"
  git clone -q "$ORIGIN" "$clone"
  git_identity "$clone"
  for pair in "$@"; do
    edit_line "$clone/docs/WP-REGISTRY.md" "${pair%%=*}" "${pair#*=}"
  done
  git -C "$clone" commit -qam "foreign: registry edit"
  git -C "$clone" push -q origin main

  if [ "${MERGE_COMMIT:-0}" -eq 1 ]; then
    git -C "$WT" fetch -q origin
    git -C "$WT" merge -q --no-edit origin/main
    OLD_HEAD=$(git -C "$WT" rev-parse HEAD)
  fi
  if [ "${REBASE_IN_PROGRESS:-0}" -eq 1 ]; then
    # Pauses after the first pick, as a killed rebase would.
    git -C "$WT" fetch -q origin
    base=$(git -C "$WT" merge-base HEAD origin/main)
    git -C "$WT" -c rebase.autostash=false rebase -x false --onto origin/main "$base" >/dev/null 2>&1 || true
    rebase_in_progress "$WT" || { echo "FAIL: setup -- rebase -x false left no rebase in progress" >&2; exit 1; }
  fi
}

# Runs close from a neutral directory; sets CLOSE_RC and CLOSE_ERR.
run_close() {  # <guard script> [extra close args]...
  local guard="$1"
  shift
  CLOSE_RC=0
  SEM_SHA_BEFORE=$(shasum "$SEM")
  CLOSE_ERR="$E2E/close.err"
  (cd "$E2E" && bash "$guard" close --wp WP-484 --slug "$SESS_SLUG" --agent fixture "$@") \
    >"$E2E/close.out" 2>"$CLOSE_ERR" || CLOSE_RC=$?
}

# First close against the mid-rebase copy, manual abort, second close.
run_inprogress() {  # <guard script>
  run_close "$1"
  FIRST_RC="$CLOSE_RC"
  FIRST_SEM_UNCHANGED=0
  semaphore_unchanged && FIRST_SEM_UNCHANGED=1
  cp "$CLOSE_ERR" "$E2E/first-close.err"
  git -C "$WT" rebase --abort >/dev/null 2>&1 || true
  run_close "$1"
}

# TERM reaches only the guard while its rebase (slowed by the git shim) runs.
run_interrupt() {  # <guard script>
  local guard_pid state_dir waited=0
  CLOSE_RC=0
  SEM_SHA_BEFORE=$(shasum "$SEM")
  CLOSE_ERR="$E2E/close.err"
  (cd "$E2E" && export PATH="$SHIM_DIR:$PATH" \
    && exec bash "$1" close --wp WP-484 --slug "$SESS_SLUG" --agent fixture) \
    >"$E2E/close.out" 2>"$CLOSE_ERR" &
  guard_pid=$!
  state_dir=$(git -C "$WT" rev-parse --path-format=absolute --git-path rebase-merge)
  until [ -e "$state_dir" ] || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [ -e "$state_dir" ] || echo "  note: the rebase never started within 60s; TERM sent anyway" >&2
  kill -TERM "$guard_pid" 2>/dev/null || true
  wait "$guard_pid" || CLOSE_RC=$?
  # A guard killed outright leaves git finishing the rebase on its own.
  waited=0
  while [ -e "$state_dir" ] && [ "$waited" -lt 150 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
}

# Each close owns a separate process group; a terminal Ctrl-C reaches the
# guard and every child in that group, without signalling the test runner.
run_group_interrupt() {  # <guard> <readiness path>
  SEM_SHA_BEFORE=$(shasum "$SEM")
  CLOSE_ERR="$E2E/close.err"
  CLOSE_RC=$(python3 - "$1" "$2" "$E2E" "$SESS_SLUG" "$SHIM_DIR" <<'PY'
import os, pathlib, signal, subprocess, sys, time
guard, ready, cwd, slug, shim = sys.argv[1:]
env = {**os.environ, "PATH": shim + os.pathsep + os.environ["PATH"]}
with open(cwd + "/close.out", "w") as out, open(cwd + "/close.err", "w") as err:
    process = subprocess.Popen(["bash", guard, "close", "--wp", "WP-484", "--slug", slug,
                                "--agent", "fixture"], cwd=cwd, env=env, stdout=out,
                               stderr=err, start_new_session=True)
    deadline = time.monotonic() + 60
    while not pathlib.Path(ready).exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.05)
    if not pathlib.Path(ready).exists():
        process.terminate()
        process.wait(timeout=20)
        raise SystemExit("close did not reach the requested interrupt point")
    os.killpg(process.pid, signal.SIGINT)
    print(process.wait(timeout=20))
PY
  )
}

run_claim_interrupt() {  # <guard> <before|after>: deterministic pause around atomic claim replacement
  local phase_guard="$E2E/phase/session-guard.sh"
  mkdir -p "$E2E/phase"
  ln -s "$ROOT_DIR/lib" "$E2E/phase/lib"
  export IWE_TEST_SIGNAL_READY="$E2E/claims-ready"
  python3 - "$1" "$phase_guard" "$2" <<'PY'
from pathlib import Path
import sys
source, target, phase = sys.argv[1:]
text = Path(source).read_text()
if phase == "before":
    anchor = '  rewritten=$(_rewrite_commit_claims_atomic '
    assert text.count(anchor) == 1
    text = text.replace(anchor, '  touch "$IWE_TEST_SIGNAL_READY"\n  sleep 3\n' + anchor)
else:
    start = text.index("_rewrite_commit_claims_atomic() {")
    end = text.index("\n_rebuild_source_for_hot_files()", start)
    body = text[start:end]
    anchor = "    os.replace(temporary, path)\n"
    assert body.count(anchor) == 1
    pause = ('    import time\n'
             '    ready = os.environ["IWE_TEST_SIGNAL_READY"]\n'
             '    if not os.path.exists(ready):\n'
             '        open(ready, "w").close()\n'
             '        time.sleep(3)\n')
    text = text[:start] + body.replace(anchor, anchor + pause) + text[end:]
Path(target).write_text(text)
PY
  run_group_interrupt "$phase_guard" "$IWE_TEST_SIGNAL_READY"
  unset IWE_TEST_SIGNAL_READY
}

# Stops at PREPARED right after the rebuild, lets origin move the hot file
# again so the prepared set is stuck, then abandons it with the rebuilt SHA.
run_abandon() {  # <guard script>
  FAULT_RC=0
  (cd "$E2E" && IWE_SESSION_GUARD_FAULT_POINT=after-prepared bash "$1" close --wp WP-484 \
    --slug "$SESS_SLUG" --agent fixture) >"$E2E/fault.out" 2>"$E2E/fault.err" || FAULT_RC=$?
  NEW_HEAD=$(git -C "$WT" rev-parse HEAD)
  CLAIM_ON_REBUILT=0
  if grep -qx "commit: DS-strategy $NEW_HEAD" "$SEM" && ! grep -qx "commit: DS-strategy $OLD_HEAD" "$SEM"; then
    CLAIM_ON_REBUILT=1
  fi
  edit_line "$E2E/foreign/docs/WP-REGISTRY.md" line7 line7-foreign
  git -C "$E2E/foreign" commit -qam "foreign: second registry edit"
  git -C "$E2E/foreign" push -q origin main
  STUCK_RC=0
  (cd "$E2E" && bash "$1" close --wp WP-484 --slug "$SESS_SLUG" --agent fixture) \
    >"$E2E/stuck.out" 2>"$E2E/stuck.err" || STUCK_RC=$?
  run_close "$1" --abandon-prepared --i-understand-loss-risk --source-commit "$NEW_HEAD" \
    --reason "hot-rebuild smoke: origin moved the hot file again after PREPARED"
}

# Assertions never abort: an unmet one is reported on stderr and marks CASE_OK.
expect_that() {  # <message> <command>...
  local message="$1"
  shift
  if ! "$@"; then
    echo "  unmet: $message" >&2
    CASE_OK=1
  fi
}

origin_has_line() {  # <line>
  git -C "$ORIGIN" show main:docs/WP-REGISTRY.md > "$E2E/registry.now"
  grep -qx "$1" "$E2E/registry.now"
}

semaphore_has_no_delivery_record() {
  ! grep -q '^close_delivery_' "$SEM"
}

semaphore_unchanged() {
  [ "$(shasum "$SEM")" = "$SEM_SHA_BEFORE" ]
}

open_semaphore_kept() {
  [ -f "$SEM" ] && [ ! -e "$SEM.closed" ]
}

close_reported_rebuild() {
  grep -q 'пересобран' "$CLOSE_ERR"
}

close_said() {  # <text> [file]
  grep -q -- "$1" "${2:-$CLOSE_ERR}"
}

rebase_in_progress() {  # <repo>
  [ -e "$(git -C "$1" rev-parse --path-format=absolute --git-path rebase-merge)" ] \
    || [ -e "$(git -C "$1" rev-parse --path-format=absolute --git-path rebase-apply)" ]
}

rebase_was_attempted() {  # <repo>
  git -C "$1" reflog show --format=%gs HEAD 2>/dev/null | grep -q '^rebase'
}

repo_is_on_tip() {  # <repo> <tip>: on its branch at <tip>, no rebase in progress, tree clean
  [ "$(git -C "$1" rev-parse HEAD)" = "$2" ] \
    && git -C "$1" symbolic-ref -q HEAD >/dev/null \
    && [ -z "$(git -C "$1" status --porcelain)" ] \
    && ! rebase_in_progress "$1"
}

copy_is_back_on_old_tip() {
  repo_is_on_tip "$WT" "$OLD_HEAD"
}

copy_head_is_old_tip() {
  [ "$(git -C "$WT" rev-parse HEAD)" = "$OLD_HEAD" ] && ! rebase_in_progress "$WT"
}

uncommitted_edit_intact() {
  [ "$(grep -c UNCOMMITTED-WORK "$WT/docs/notes.md")" -eq 1 ] && [ -z "$(git -C "$WT" stash list)" ]
}

closed_claims_name_prepared_head() {
  local head
  head=$(sed -n 's/^close_delivery_source_head: //p' "$SEM.closed")
  [ -n "$head" ] && grep -qx "commit: DS-strategy $head" "$SEM.closed"
}

assert_other() {
  expect_that "close exits 0 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 0
  expect_that "session reached .closed without abandon or manual steps" test -e "$SEM.closed"
  expect_that ".open is gone after the close" test ! -e "$SEM"
  expect_that "origin holds the session edit" origin_has_line line2-session
  expect_that "origin keeps the foreign edit" origin_has_line line8-foreign
  expect_that "close reports the rebuild" close_reported_rebuild
  expect_that "the note-commit claim names the rebuilt (prepared) commit" closed_claims_name_prepared_head
}

assert_same() {
  expect_that "close refuses with exit 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "close names the conflicting file" close_said 'конфликт в docs/WP-REGISTRY.md'
  expect_that "PREPARED was not written to the semaphore" semaphore_has_no_delivery_record
  expect_that "the semaphore is byte-for-byte unchanged" semaphore_unchanged
  expect_that ".open kept, nothing closed" open_semaphore_kept
  expect_that "the copy is back on its previous tip, no rebase left in progress" copy_is_back_on_old_tip
  expect_that "origin was not touched" origin_has_line line2-foreign
}

assert_delivered() {
  expect_that "close exits 0 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 0
  expect_that "session reached .closed" test -e "$SEM.closed"
  expect_that "origin holds the first (already delivered) edit" origin_has_line line2-session
  expect_that "origin holds the second edit" origin_has_line line6-session
  expect_that "origin keeps the foreign edit" origin_has_line line8-foreign
  expect_that "close reports the rebuild" close_reported_rebuild
}

assert_duplicate() {
  expect_that "close refuses with exit 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "PREPARED was not written to the semaphore" semaphore_has_no_delivery_record
  expect_that "the copy is back on its previous tip" copy_is_back_on_old_tip
}

assert_dirty() {  # dirtydup and dirtyother
  expect_that "close refuses with exit 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "close names the dirty copy, before any rebase" close_said 'не полностью clean'
  expect_that "no rebase was attempted on the copy" test ! "$(rebase_was_attempted "$WT" && echo yes)"
  expect_that "the copy stays on its previous tip" copy_head_is_old_tip
  expect_that "the uncommitted edit survived and nothing was stashed" uncommitted_edit_intact
  expect_that "the semaphore is byte-for-byte unchanged" semaphore_unchanged
  expect_that "PREPARED was not written to the semaphore" semaphore_has_no_delivery_record
}
assert_dirtydup() { assert_dirty; }
assert_dirtyother() {
  assert_dirty
  expect_that "origin was not touched" origin_has_line line2
}

assert_inprogress() {
  expect_that "first close refuses with exit 7 (got $FIRST_RC)" test "$FIRST_RC" -eq 7
  expect_that "first close hints at git rebase --abort" close_said 'rebase --abort' "$E2E/first-close.err"
  expect_that "first close left the semaphore byte-for-byte unchanged" test "$FIRST_SEM_UNCHANGED" -eq 1
  expect_that "close after the manual abort exits 0 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 0
  expect_that "session reached .closed after the manual abort" test -e "$SEM.closed"
  expect_that "origin holds the session edit" origin_has_line line2-session
  expect_that "origin keeps the foreign edit" origin_has_line line8-foreign
}

assert_interrupt() {
  expect_that "interrupted close exits 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "close reports the interrupted rebuild" close_said 'прервана сигналом'
  expect_that "the copy is back on its previous tip, no rebase left in progress" copy_is_back_on_old_tip
  expect_that "the semaphore is byte-for-byte unchanged" semaphore_unchanged
  expect_that "PREPARED was not written to the semaphore" semaphore_has_no_delivery_record
  expect_that "an interruption is not reported as a conflict" test ! "$(close_said 'конфликт в' && echo yes)"
}
assert_groupinterrupt() { assert_interrupt; }
assert_claimsbefore() { assert_interrupt; }
assert_claimsafter() { assert_interrupt; }

assert_empty() {
  expect_that "empty commit refuses with exit 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "the empty commit is identified explicitly" close_said 'пустой source-коммит'
  expect_that "no rebase was attempted" test ! "$(rebase_was_attempted "$WT" && echo yes)"
  expect_that "the copy stays on its previous tip" copy_is_back_on_old_tip
  expect_that "the semaphore is byte-for-byte unchanged" semaphore_unchanged
  expect_that "PREPARED was not written" semaphore_has_no_delivery_record
}
assert_emptycheckmissing() { assert_empty; }

assert_merge() {
  expect_that "close refuses with exit 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "close names the merge commit as the reason" close_said 'merge-коммит'
  expect_that "no rebase was attempted on the copy" test ! "$(rebase_was_attempted "$WT" && echo yes)"
  expect_that "the copy stays on its previous tip" copy_is_back_on_old_tip
  expect_that "the semaphore is byte-for-byte unchanged" semaphore_unchanged
}

assert_casbroken() {
  expect_that "close refuses with exit 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "close says the hot-file check did not run, with its reason" close_said 'проверка горячих файлов не отработала: git rev-list timed out'
  expect_that "no rebase was attempted on the copy" test ! "$(rebase_was_attempted "$WT" && echo yes)"
  expect_that "the copy stays on its previous tip" copy_is_back_on_old_tip
  expect_that "the semaphore is byte-for-byte unchanged" semaphore_unchanged
}

assert_canon() {
  expect_that "close refuses with exit 7 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 7
  expect_that "close names the unlinked copy as the reason" close_said 'не является связанной копией'
  expect_that "the canonical branch was neither rebased nor reset" repo_is_on_tip "$GOV" "$OLD_HEAD"
  expect_that "no rebase was attempted on the canonical checkout" test ! "$(rebase_was_attempted "$GOV" && echo yes)"
  expect_that "the semaphore is byte-for-byte unchanged" semaphore_unchanged
}

assert_abandon() {
  expect_that "the first close stopped at PREPARED after the rebuild (got $FAULT_RC)" test "$FAULT_RC" -eq 99
  expect_that "the note-commit claim was rewritten from the old SHA to the rebuilt one" test "$CLAIM_ON_REBUILT" -eq 1
  expect_that "the retry after origin moved again is refused with exit 7 (got $STUCK_RC)" test "$STUCK_RC" -eq 7
  expect_that "the retry names the unpublished prepared set" close_said 'не опубликован' "$E2E/stuck.err"
  expect_that "close --abandon-prepared with the rebuilt SHA exits 0 (got $CLOSE_RC)" test "$CLOSE_RC" -eq 0
  expect_that "session reached .closed" test -e "$SEM.closed"
  expect_that ".closed carries the manual abandon attestation" close_said 'close_publish_proof: manual-abandon-attestation/v1' "$SEM.closed"
}

# A mutant is the real script with one or more statements replaced. A missing
# anchor aborts the test: the mutation would otherwise test nothing. Sets
# MUTANT_GUARD.
make_mutant() {  # <name> <original text> <replacement text> [<original> <replacement>]...
  local name="$1" dir="$TEST_ROOT/mutant-$1"
  shift
  mkdir -p "$dir"
  ln -s "$ROOT_DIR/lib" "$dir/lib"
  python3 - "$REAL_GUARD" "$dir/session-guard.sh" "$@" <<'PY' \
    || { echo "FAIL: cannot build mutant $name" >&2; exit 1; }
import sys

source, target = sys.argv[1:3]
pairs = sys.argv[3:]
text = open(source, encoding="utf-8").read()
for old, new in zip(pairs[::2], pairs[1::2]):
    if text.count(old) != 1:
        raise SystemExit("mutation anchor not found exactly once: " + old)
    text = text.replace(old, new)
open(target, "w", encoding="utf-8").write(text)
PY
  MUTANT_GUARD="$dir/session-guard.sh"
}

FAILURES=0
SANDBOX_N=0
check_case() {  # <label> <expect: pass|fail> <kind> <guard>
  local label="$1" expectation="$2" kind="$3" guard="$4"
  case ",${IWE_HOT_REBUILD_CASES:-all}," in
    *,all,*|*,"$kind",*) ;;
    *) return 0 ;;
  esac
  SANDBOX_N=$((SANDBOX_N + 1))
  case "$kind" in
    other|interrupt|groupinterrupt|claimsbefore|claimsafter|abandon) build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign ;;
    empty|emptycheckmissing)
      EMPTY_COMMIT=1 build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign
      [ "$kind" != emptycheckmissing ] || rm "$GOV/scripts/hot_publish_cas.py" ;;
    same) build_sandbox "$kind-$SANDBOX_N" line2=line2-foreign ;;
    duplicate) build_sandbox "$kind-$SANDBOX_N" line2=line2-session line8=line8-foreign ;;
    delivered) FIRST_COMMIT_PUBLISHED=1 build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign ;;
    dirtydup) DIRTY_COPY=1 AUTOSTASH=1 build_sandbox "$kind-$SANDBOX_N" line2=line2-session line8=line8-foreign ;;
    dirtyother) DIRTY_COPY=1 AUTOSTASH=1 build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign ;;
    inprogress) REBASE_IN_PROGRESS=1 build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign ;;
    merge) MERGE_COMMIT=1 build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign ;;
    casbroken) CAS_BROKEN=1 build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign ;;
    canon) CANON_SEMAPHORE=1 build_sandbox "$kind-$SANDBOX_N" line8=line8-foreign ;;
  esac
  case "$kind" in
    inprogress) run_inprogress "$guard" ;;
    interrupt) run_interrupt "$guard" ;;
    groupinterrupt) run_group_interrupt "$guard" "$(git -C "$WT" rev-parse --path-format=absolute --git-path rebase-merge)" ;;
    claimsbefore) run_claim_interrupt "$guard" before ;;
    claimsafter) run_claim_interrupt "$guard" after ;;
    abandon) run_abandon "$guard" ;;
    *) run_close "$guard" ;;
  esac
  CASE_OK=0
  "assert_$kind" 2>"$TEST_ROOT/case.err"
  if { [ "$expectation" = pass ] && [ "$CASE_OK" -eq 0 ]; } \
      || { [ "$expectation" = fail ] && [ "$CASE_OK" -ne 0 ]; }; then
    echo "PASS: $label"
    [ "$expectation" = pass ] || sed 's/^ *unmet:/    caught by:/' "$TEST_ROOT/case.err"
  else
    echo "FAIL: $label" >&2
    cat "$TEST_ROOT/case.err" >&2
    sed 's/^/  close.err: /' "$CLOSE_ERR" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

check_case "other-line edit of the registry: close succeeds after the rebuild, claims follow" pass other "$REAL_GUARD"
check_case "same-line edit: exit 7 naming the file, PREPARED not written, copy back on its tip" pass same "$REAL_GUARD"
check_case "duplicate edit: rebuilt set not equivalent, exit 7, copy restored" pass duplicate "$REAL_GUARD"
check_case "first commit already delivered: only the undelivered one is rebuilt" pass delivered "$REAL_GUARD"
check_case "dirty copy + autostash + duplicate edit: refused before rebase, edit survives" pass dirtydup "$REAL_GUARD"
check_case "dirty copy + autostash + other-line edit: refused, copy stays on its tip" pass dirtyother "$REAL_GUARD"
check_case "copy left mid-rebase: refused with the abort hint, closes after a manual abort" pass inprogress "$REAL_GUARD"
check_case "TERM during the rebase: copy back on its tip, exit 7" pass interrupt "$REAL_GUARD"
check_case "Ctrl-C to the process group is reported as an interruption" pass groupinterrupt "$REAL_GUARD"
check_case "Ctrl-C before claim rewrite restores the old tip and claims" pass claimsbefore "$REAL_GUARD"
check_case "Ctrl-C after atomic claim replacement restores the old tip and claims" pass claimsafter "$REAL_GUARD"
check_case "empty source commit is rejected before PREPARED and rebase" pass empty "$REAL_GUARD"
check_case "empty source commit is rejected even without the hot-file check" pass emptycheckmissing "$REAL_GUARD"
check_case "merge commit in the set: refused as such, no rebase attempted" pass merge "$REAL_GUARD"
check_case "hot-file check itself fails: refused with its reason, no rebase attempted" pass casbroken "$REAL_GUARD"
check_case "semaphore names the canonical checkout: refused, canon untouched" pass canon "$REAL_GUARD"
check_case "stuck after a rebuild: --abandon-prepared with the rebuilt SHA passes" pass abandon "$REAL_GUARD"

REBASE='git -C "$worktree" -c rebase.autoStash=false rebase --onto "$remote_head" "$old_base"'
NOSTASH='-c rebase.autoStash=false '
ABORT='git -C "$1" rebase --abort >/dev/null 2>&1 || true'
RESET='git -C "$1" reset --hard --quiet "$2" 2>/dev/null || true'
FILTER='old_commits=$(_undelivered_source_commits "$semaphore" "$worktree" "$remote_head" $old_commits)'
PRECLEAN='|| fail "close: isolated worktree не полностью clean (включая ignored/untracked); PREPARED не пишу" 7'
INPROGRESS='if _rebase_in_progress "$CLOSING_WORKTREE" \
        || ! git -C "$CLOSING_WORKTREE" symbolic-ref -q HEAD >/dev/null 2>&1; then'
TRAP="trap '_rebuild_interrupted \"\$worktree\" \"\$old_head\" \"\$semaphore\" \"\$old_commits\" \"\$rollback_new_commits\"' INT TERM HUP"
MERGETEXT='*"single-parent source commits"*)'
CASTEXT='fail "close: проверка горячих файлов не отработала: ${cas_reason}; rebase не запускался, PREPARED не записан, копия не тронута" 7 ;;'
LINKED='_isolated_copy_is_linked "$worktree" \'
CLAIMS='rewritten=$(_rewrite_commit_claims_atomic "$semaphore" "$GOV_REPO" "$old_commits" "$new_commits") || {'
make_mutant no-rebase "$REBASE" 'true'
check_case "mutant without rebase: the other-line case must fail" fail other "$MUTANT_GUARD"
make_mutant no-abort "$ABORT" ':'
check_case "mutant without abort: the same-line case must fail" fail same "$MUTANT_GUARD"
make_mutant no-reset "$RESET" 'true'
check_case "mutant without restore: the duplicate case must fail" fail duplicate "$MUTANT_GUARD"
make_mutant no-filter "$FILTER" 'old_commits=$old_commits'
check_case "mutant checking delivered commits too: the delivered case must fail" fail delivered "$MUTANT_GUARD"
make_mutant no-preclean "$PRECLEAN" '|| true'
check_case "mutant without the clean check before the rebuild: the dirty other-line case must fail" fail dirtyother "$MUTANT_GUARD"
# The autostash switch only matters once the clean check is gone (it refuses
# every dirty copy first), so its mutant drops both.
make_mutant no-preclean-autostash "$PRECLEAN" '|| true' "$NOSTASH" ''
check_case "mutant without the clean check and with autostash: the dirty duplicate case must fail (edit lost)" fail dirtydup "$MUTANT_GUARD"
make_mutant no-inprogress "$INPROGRESS" 'if false; then'
check_case "mutant without the mid-rebase check: the in-progress case must fail" fail inprogress "$MUTANT_GUARD"
make_mutant no-trap "$TRAP" ':'
check_case "mutant without the signal trap: the interrupt case must fail" fail interrupt "$MUTANT_GUARD"
make_mutant no-merge-text "$MERGETEXT" '"__no_merge_branch__")'
check_case "mutant without the merge-commit refusal: the merge case must fail" fail merge "$MUTANT_GUARD"
make_mutant no-cas-text "$CASTEXT" ';;'
check_case "mutant rebasing after a failed check: the broken-check case must fail" fail casbroken "$MUTANT_GUARD"
make_mutant no-linked "$LINKED" 'true \'
check_case "mutant without the linked-copy check: the canon case must fail" fail canon "$MUTANT_GUARD"
make_mutant no-claims "$CLAIMS" 'rewritten=0 || {'
check_case "mutant leaving the claims on the old SHAs: the abandon case must fail" fail abandon "$MUTANT_GUARD"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS: session-guard-close-hot-rebuild-smoke.sh"
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
