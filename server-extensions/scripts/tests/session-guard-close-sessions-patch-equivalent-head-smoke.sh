#!/usr/bin/env bash
# Regression for WP-530 Ф67 (peer-session 2026-09-25-16-wp530-close-hygiene-systemic,
# Claude+Kimi+Codex, 25.09.2026): the shared MC-sessions checkout is delivered by
# `ds-publish.sh --exact-commit` -- a cherry-pick under a different SHA on
# origin/main -- so between two rebases its HEAD is never an ancestor of
# origin/main. The scoped fallback (scenario F of
# session-guard-close-sessions-repo-scope-fallback-smoke.sh) only rescues a close
# whose `file:` claims cover every path of every claimed commit; live 25.09 three
# finished sessions had peer-reply files that `note-file` never registered and
# kept their semaphores open all day. This exercises the patch-equivalence
# fallback of _repo_head_has_publish_proof for the sessions checkout:
#   P: incomplete file claims, every local commit patch-equivalent on origin -> close 0
#   Q: P plus one local commit whose content is absent from origin          -> close 7
#   R: a merge commit inside origin/main..HEAD                              -> close 7
#   S: the SAME shape on the GOVERNANCE checkout must NOT be rescued        -> close 7
#      (the fallback is gated to the sessions-checkout role; cold review Ф67)
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-patch-equiv.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Exact stderr markers of the guard -- the assertions below are on these strings,
# not on the exit code alone (P1 of DP.SC.172: a test must check the observable
# result, not just "it did not crash").
FALLBACK_MARK='patch-эквивалентны свежему origin/main (cherry-pick delivery fallback)'
ANCESTRY_REFUSAL='HEAD sessions checkout не достижим из origin/main; есть неподтверждённая доставка'
GOVERNANCE_REFUSAL='HEAD governance checkout не достижим из origin/main; есть неподтверждённая доставка'
SCOPE_REFUSAL='scoped publish proof: нет полного repo-qualified commit scope'
MERGE_REFUSAL='publish proof: merge commits in origin/main..HEAD are not allowed'

# make_fixture <root>: a governance repo + a sessions repo, each with a bare
# origin, under one root; exports the guard's environment for that root. P/Q/R
# share one fixture (their sessions history is meant to accumulate); S gets its
# own so its governance divergence cannot leak into the other scenarios.
make_fixture() {
  local root="$1"
  REPO="$root/DS-strategy"
  ORIGIN="$root/origin.git"
  mkdir -p "$REPO/inbox/agent/tasks" "$REPO/scripts"
  git init --bare -q -b main "$ORIGIN"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" remote add origin "$ORIGIN"
  cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
  chmod +x "$REPO/scripts/process-runner.py"
  git -C "$REPO" add scripts/process-runner.py
  git -C "$REPO" commit -qm init
  git -C "$REPO" push -q origin HEAD:main

  SESSIONS="$root/MC-sessions"
  SESSIONS_ORIGIN="$root/sessions-origin.git"
  mkdir -p "$SESSIONS"
  git init --bare -q -b main "$SESSIONS_ORIGIN"
  git -C "$SESSIONS" init -q
  git -C "$SESSIONS" config user.email test@example.com
  git -C "$SESSIONS" config user.name "Test"
  git -C "$SESSIONS" remote add origin "$SESSIONS_ORIGIN"
  echo seed > "$SESSIONS/README.md"
  git -C "$SESSIONS" add README.md
  git -C "$SESSIONS" commit -qm init
  git -C "$SESSIONS" push -q origin HEAD:main
  SESSIONS_BRANCH=$(git -C "$SESSIONS" rev-parse --abbrev-ref HEAD)

  export IWE_ROOT="$root"
  export IWE_GOVERNANCE_REPO="DS-strategy"
  export IWE_AGENT="fixture"
  export IWE_FROZEN_CANONICAL_PATH=""
}

write_orz() {
  local orz_path="$1"
  mkdir -p "$(dirname "$orz_path")"
  cat > "$orz_path" <<'EOF'
---
date: 2026-09-25
type: work
wp: WP-530
duration_h: 0.1
artifacts: []
agent: fixture
---

# Fixture session

## Главный инсайт
fixture

## Контекст
fixture

## Достигнуто
fixture

## Ключевые решения
fixture
EOF
}

write_peer_reply() {  # <path> -- the file the live sessions never registered
  printf 'peer reply, never registered via note-file\n' > "$1"
}

write_run_card() {  # <slug> <harness session id>
  cat > "$REPO/inbox/agent/tasks/RUN-quick-close-$1.md" <<EOF
---
process_id: quick-close
run_id: quick-close-$1
requested_slug: $1
status: completed
current_step: done
owner_session_id: $2
results:
  gather-session-facts:
    wp: WP-530
---
EOF
}

open_session() {  # <slug> <harness session id> -> semaphore path on stdout
  CLAUDE_CODE_SESSION_ID="$2" bash "$GUARD" open --wp WP-530 --task fixture --slug "$1" --agent fixture >/dev/null
  grep -l "^slug: $1\$" "$IWE_ROOT"/.iwe-runtime/sessions/fixture-*.open
}

orz_of() {  # <semaphore>
  grep '^orz_file: ' "$1" | cut -d' ' -f2-
}

foreign_advance() {  # <bare origin> <tag> -- unrelated history lands on that origin/main
  local clone="$TEST_ROOT/foreign-$2"
  git clone -q "$1" "$clone"
  git -C "$clone" config user.email foreign@test
  git -C "$clone" config user.name foreign
  echo "unrelated foreign work $2" > "$clone/foreign-$2.txt"
  git -C "$clone" add "foreign-$2.txt"
  git -C "$clone" commit -qm "foreign session advances origin ($2)"
  git -C "$clone" push -q origin HEAD:main
}

commit_own_work() {  # <orz basename> <peer-reply basename> <message> -> own SHA on stdout
  write_orz "$SESSIONS/$1"
  write_peer_reply "$SESSIONS/$2"
  git -C "$SESSIONS" add "$1" "$2"
  git -C "$SESSIONS" commit -qm "$3"
  git -C "$SESSIONS" rev-parse HEAD
}

republish_same_content() {  # <tag> <orz basename> <peer-reply basename>
  # What isolate-push.sh does from a fresh worktree: same patch, another SHA.
  local clone="$TEST_ROOT/republish-$1"
  git clone -q "$SESSIONS_ORIGIN" "$clone"
  git -C "$clone" config user.email republish@test
  git -C "$clone" config user.name republish
  write_orz "$clone/$2"
  write_peer_reply "$clone/$3"
  git -C "$clone" add "$2" "$3"
  git -C "$clone" commit -qm "same content republished onto fresh sessions origin/main ($1)"
  git -C "$clone" push -q origin HEAD:main
}

assert_diverged() {  # <repo dir> <label>
  git -C "$1" fetch -q origin main
  if git -C "$1" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    fail "$2: fixture setup -- local HEAD is still an ancestor of origin/main, divergence not achieved"
  fi
}

claim_incomplete_scope() {  # <semaphore> <slug> <orz basename> <repo basename> <own sha>
  # The extra committed file is deliberately NOT claimed: this is the live 25.09
  # shape, and it makes _repo_scope_has_publish_proof refuse ("нет полного
  # repo-qualified commit scope") so only the new fallback could rescue the close.
  {
    echo "file: inbox/agent/tasks/RUN-quick-close-$2.md"
    echo "file: $3"
    echo "commit: $4 $5"
  } >> "$1"
}

close_session() {  # <slug> <harness session id> -> combined output in $CLOSE_OUT, rc in $CLOSE_RC
  # No `OUT=$(close_session …)` at the call sites: a command substitution runs in
  # a subshell and the rc assigned here would never reach the caller.
  CLOSE_RC=0
  CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="$2" bash "$GUARD" close --wp WP-530 --slug "$1" --agent fixture 2>&1) || CLOSE_RC=$?
}

make_fixture "$TEST_ROOT/f1"

# --- P: honest delivery under another SHA, incomplete claims -> fallback closes.
SEM_P=$(open_session patch-equiv-p session-P)
ORZ_P=$(orz_of "$SEM_P")
foreign_advance "$SESSIONS_ORIGIN" p
OWN_P=$(commit_own_work "$ORZ_P" "peer-reply-p.md" "own work on the old base (P)")
assert_diverged "$SESSIONS" P
republish_same_content p "$ORZ_P" "peer-reply-p.md"
write_run_card patch-equiv-p session-P
claim_incomplete_scope "$SEM_P" patch-equiv-p "$ORZ_P" "$(basename "$SESSIONS")" "$OWN_P"

close_session patch-equiv-p session-P; OUT_P=$CLOSE_OUT
[ "$CLOSE_RC" -eq 0 ] || fail "P: close refused an honestly delivered session (rc $CLOSE_RC): $OUT_P"
grep -qF "$FALLBACK_MARK" <<<"$OUT_P" \
  || fail "P: close passed but not through the patch-equivalence fallback: $OUT_P"
grep -qF "$SCOPE_REFUSAL" <<<"$OUT_P" \
  && fail "P: scoped fallback ran although the patch-equivalence fallback must accept first: $OUT_P"
echo "PASS: P -- diverged MC-sessions with unregistered peer files closes when every local commit is patch-equivalent on origin/main"

# --- Q: same shape plus a local commit that is NOT on origin -> must refuse.
SEM_Q=$(open_session patch-equiv-q session-Q)
ORZ_Q=$(orz_of "$SEM_Q")
foreign_advance "$SESSIONS_ORIGIN" q
OWN_Q=$(commit_own_work "$ORZ_Q" "peer-reply-q.md" "own work on the old base (Q)")
republish_same_content q "$ORZ_Q" "peer-reply-q.md"
echo "never delivered anywhere" > "$SESSIONS/undelivered-q.md"
git -C "$SESSIONS" add undelivered-q.md
git -C "$SESSIONS" commit -qm "local commit with content absent from origin (Q)"
assert_diverged "$SESSIONS" Q
write_run_card patch-equiv-q session-Q
claim_incomplete_scope "$SEM_Q" patch-equiv-q "$ORZ_Q" "$(basename "$SESSIONS")" "$OWN_Q"

close_session patch-equiv-q session-Q; OUT_Q=$CLOSE_OUT
[ "$CLOSE_RC" -eq 7 ] || fail "Q: expected exit 7 for undelivered local content, got $CLOSE_RC: $OUT_Q"
grep -qF "$FALLBACK_MARK" <<<"$OUT_Q" \
  && fail "Q: patch-equivalence fallback accepted a checkout with undelivered content: $OUT_Q"
grep -qF "$SCOPE_REFUSAL" <<<"$OUT_Q" || fail "Q: scoped fallback refusal missing: $OUT_Q"
grep -qF "$ANCESTRY_REFUSAL" <<<"$OUT_Q" || fail "Q: ancestry refusal missing: $OUT_Q"
[ -f "$SEM_Q" ] || fail "Q: semaphore was removed although close refused"
echo "PASS: Q -- a local commit with content absent from origin/main still blocks close (exit 7, no fallback marker)"

# --- R: a merge commit in origin/main..HEAD -> fail closed with the merge diagnostic.
SEM_R=$(open_session patch-equiv-r session-R)
ORZ_R=$(orz_of "$SEM_R")
foreign_advance "$SESSIONS_ORIGIN" r
OWN_R=$(commit_own_work "$ORZ_R" "peer-reply-r.md" "own work on the old base (R)")
republish_same_content r "$ORZ_R" "peer-reply-r.md"
git -C "$SESSIONS" checkout -q -b side-r
echo "side branch work" > "$SESSIONS/side-r.md"
git -C "$SESSIONS" add side-r.md
git -C "$SESSIONS" commit -qm "side branch (R)"
git -C "$SESSIONS" checkout -q "$SESSIONS_BRANCH"
git -C "$SESSIONS" merge -q --no-ff -m "merge side branch (R)" side-r
[ "$(git -C "$SESSIONS" rev-list --count --merges "origin/main..HEAD")" -ge 1 ] \
  || fail "R: fixture setup -- no merge commit in origin/main..HEAD"
write_run_card patch-equiv-r session-R
claim_incomplete_scope "$SEM_R" patch-equiv-r "$ORZ_R" "$(basename "$SESSIONS")" "$OWN_R"

close_session patch-equiv-r session-R; OUT_R=$CLOSE_OUT
[ "$CLOSE_RC" -eq 7 ] || fail "R: expected exit 7 for a merge commit in the range, got $CLOSE_RC: $OUT_R"
grep -qF "$MERGE_REFUSAL" <<<"$OUT_R" || fail "R: merge diagnostic missing: $OUT_R"
grep -qF "$FALLBACK_MARK" <<<"$OUT_R" \
  && fail "R: patch-equivalence fallback accepted a range containing a merge commit: $OUT_R"
echo "PASS: R -- a merge commit inside origin/main..HEAD fails closed with the merge diagnostic"

# --- S: governance checkout in the P shape (diverged, patch-equivalent, incomplete
# claims) -- the fallback is gated to the sessions role and must NOT rescue it.
make_fixture "$TEST_ROOT/f2"
SEM_S=$(open_session gov-patch-equiv-s session-S)
ORZ_S=$(orz_of "$SEM_S")
# Deliver the ORZ plainly so MC-sessions stays an ancestor of its origin/main and
# the only refusal left can come from the governance checkout.
write_orz "$SESSIONS/$ORZ_S"
git -C "$SESSIONS" add "$ORZ_S"
git -C "$SESSIONS" commit -qm "own ORZ, pushed plainly (S)"
git -C "$SESSIONS" push -q origin HEAD:main
foreign_advance "$ORIGIN" s
mkdir -p "$REPO/inbox/WP-530"
echo "governance note S" > "$REPO/inbox/WP-530/s-note.md"
git -C "$REPO" add inbox/WP-530/s-note.md
git -C "$REPO" commit -qm "own governance work on the old base (S)"
OWN_S=$(git -C "$REPO" rev-parse HEAD)
REPUB_S="$TEST_ROOT/republish-gov-s"
git clone -q "$ORIGIN" "$REPUB_S"
git -C "$REPUB_S" config user.email republish@test
git -C "$REPUB_S" config user.name republish
mkdir -p "$REPUB_S/inbox/WP-530"
echo "governance note S" > "$REPUB_S/inbox/WP-530/s-note.md"
git -C "$REPUB_S" add inbox/WP-530/s-note.md
git -C "$REPUB_S" commit -qm "same governance content republished under another SHA (S)"
git -C "$REPUB_S" push -q origin HEAD:main
assert_diverged "$REPO" S
git -C "$REPO" cherry origin/main "$OWN_S" "$OWN_S~1" | grep -q '^- ' \
  || fail "S: fixture setup -- governance commit is not patch-equivalent on origin/main"
write_run_card gov-patch-equiv-s session-S
claim_incomplete_scope "$SEM_S" gov-patch-equiv-s "$ORZ_S" "$(basename "$REPO")" "$OWN_S"

close_session gov-patch-equiv-s session-S; OUT_S=$CLOSE_OUT
[ "$CLOSE_RC" -eq 7 ] || fail "S: expected exit 7 -- governance checkout must keep the strict proof, got $CLOSE_RC: $OUT_S"
grep -qF "$FALLBACK_MARK" <<<"$OUT_S" \
  && fail "S: patch-equivalence fallback leaked to the governance checkout: $OUT_S"
grep -qF "$GOVERNANCE_REFUSAL" <<<"$OUT_S" || fail "S: governance ancestry refusal missing: $OUT_S"
echo "PASS: S -- the same diverged-but-equivalent shape on the governance checkout is still refused (fallback gated to sessions role)"

echo "OK: session-guard sessions-checkout patch-equivalence fallback (P/Q/R/S)"
