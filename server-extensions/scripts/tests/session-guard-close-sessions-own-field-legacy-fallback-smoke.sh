#!/usr/bin/env bash
# Regression for WP-484 own-field mirror fix (17.09, peer-session
# 2026-09-17-02-own-field-mirror-fix, Claude+Codex): _repo_scope_has_publish_proof's
# own_field branch only consulted the caller-resolved legacy fallback when the
# semaphore was "structurally legacy" (all three scope fields absent) -- a
# semaphore missing exactly ONE field (governance_worktree present,
# orz_sessions_dir absent) fell straight to refusal, live-reproduced closing
# the 16.09 session that fixed the mirror-image other_field branch. The
# sessions-checkout call site also passed no legacy fallback at all, on the
# now-disproved assumption that `open()` always writes orz_sessions_dir.
#
# Divergence is engineered exactly like the "находка 1" fixture (foreign push
# + republish under a different SHA) -- without it, MC-sessions HEAD stays a
# fast-forward of origin/main and the bare ancestry check in
# _repo_head_has_publish_proof passes trivially, never even reaching the
# scoped fallback this phase is about (first draft of this fixture made
# exactly that mistake: scenario I "passed" for the wrong reason until this
# was added).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-own-field-legacy.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/inbox/agent/tasks" "$REPO/scripts"
git init --bare -q "$ORIGIN"
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

SESSIONS="$TEST_ROOT/MC-sessions"
SESSIONS_ORIGIN="$TEST_ROOT/sessions-origin.git"
mkdir -p "$SESSIONS"
git init --bare -q "$SESSIONS_ORIGIN"
git -C "$SESSIONS" init -q
git -C "$SESSIONS" config user.email test@example.com
git -C "$SESSIONS" config user.name "Test"
git -C "$SESSIONS" remote add origin "$SESSIONS_ORIGIN"
echo seed > "$SESSIONS/README.md"
git -C "$SESSIONS" add README.md
git -C "$SESSIONS" commit -qm init
git -C "$SESSIONS" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

write_orz() {
  local orz_path="$1"
  mkdir -p "$(dirname "$orz_path")"
  cat > "$orz_path" <<'EOF'
---
date: 2026-09-17
type: work
wp: WP-484
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

strip_orz_sessions_dir() {
  local sem="$1"
  grep -qE '^governance_worktree: ' "$sem" \
    || { echo "FAIL: fixture setup -- expected governance_worktree: to survive stripping" >&2; exit 1; }
  grep -vE '^orz_sessions_dir: ' "$sem" > "$sem.stripped"
  mv "$sem.stripped" "$sem"
}

# Diverge MC-sessions origin with unrelated foreign history -- same shape as
# "находка 1"'s scenario F, shared by every scenario below so each one
# actually exercises the scoped fallback instead of the bare ancestry check.
diverge_sessions_origin() {
  local tag="$1"
  local foreign="$TEST_ROOT/foreign-session-$tag"
  git clone -q "$SESSIONS_ORIGIN" "$foreign"
  git -C "$foreign" config user.email foreign@test
  git -C "$foreign" config user.name foreign
  echo "unrelated foreign work $tag" > "$foreign/foreign-$tag.txt"
  git -C "$foreign" add "foreign-$tag.txt"
  git -C "$foreign" commit -qm "foreign session advances sessions origin ($tag)"
  git -C "$foreign" push -q origin HEAD:main
}

# Republish the given ORZ content onto the now-foreign-advanced sessions
# origin/main under a DIFFERENT sha -- exactly what isolate-push.sh does from
# an isolated worktree while this shared checkout stays behind.
republish_orz() {
  local tag="$1" orz_basename="$2"
  local republish="$TEST_ROOT/republish-sessions-$tag"
  git clone -q "$SESSIONS_ORIGIN" "$republish"
  git -C "$republish" config user.email republish@test
  git -C "$republish" config user.name republish
  write_orz "$republish/$orz_basename"
  git -C "$republish" add "$orz_basename"
  git -C "$republish" commit -qm "own ORZ content, republished onto fresh sessions origin/main ($tag)"
  git -C "$republish" push -q origin HEAD:main
}

# --- Scenario H (acceptance criterion, live incident this phase closes): a
# partially-legacy semaphore (governance_worktree present, orz_sessions_dir
# absent -- exactly the shape found live on 2026-09-16-28's own semaphore,
# opened before that night's write-side self-check) must still close when
# this session's own MC-sessions delivery was honest, even though MC-sessions
# has genuinely diverged from origin/main under it (the everyday shape of a
# shared checkout, not an edge case).
CLAUDE_CODE_SESSION_ID="session-H" bash "$GUARD" open --wp WP-484 --task fixture --slug own-field-h --agent fixture >/dev/null
SEM_H=$(grep -l '^slug: own-field-h$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
grep -q '^orz_sessions_dir: ' "$SEM_H" \
  || { echo "FAIL: fixture setup -- modern open() did not write orz_sessions_dir" >&2; exit 1; }
ORZ_BASENAME_H=$(grep '^orz_file: ' "$SEM_H" | cut -d' ' -f2-)

diverge_sessions_origin h
write_orz "$SESSIONS/$ORZ_BASENAME_H"
git -C "$SESSIONS" add "$ORZ_BASENAME_H"
git -C "$SESSIONS" commit -qm "own ORZ content, not yet fast-forwarded onto foreign history (H)"
if git -C "$SESSIONS" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  echo "FAIL: fixture setup -- local HEAD is still an ancestor of origin/main, divergence not achieved (H)" >&2
  exit 1
fi
republish_orz h "$ORZ_BASENAME_H"
strip_orz_sessions_dir "$SEM_H"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-own-field-h.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-own-field-h
requested_slug: own-field-h
status: completed
current_step: done
owner_session_id: session-H
results:
  gather-session-facts:
    wp: WP-484
---
EOF
{
  echo "file: inbox/agent/tasks/RUN-quick-close-own-field-h.md"
  echo "file: $ORZ_BASENAME_H"
  echo "commit: $(basename "$SESSIONS") $(git -C "$SESSIONS" rev-parse HEAD)"
} >> "$SEM_H"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-H" bash "$GUARD" close --wp WP-484 --slug own-field-h --agent fixture 2>&1); then
  echo "PASS: partially-legacy sessions-checkout semaphore (orz_sessions_dir absent, governance_worktree present) closes via own-field legacy fallback on a diverged MC-sessions checkout"
else
  echo "FAIL: close still refuses a partially-legacy semaphore with honest, diverged-but-delivered MC-sessions content: $CLOSE_OUT" >&2
  exit 1
fi

# --- Scenario I (regression, must stay caught): same partially-legacy shape
# and same divergence as H, but own_field is AMBIGUOUS (two conflicting
# orz_sessions_dir lines) instead of absent -- the exact-match branch's own
# ambiguity guard must still win, the new fallback must never paper over a
# duplicated field.
CLAUDE_CODE_SESSION_ID="session-I" bash "$GUARD" open --wp WP-484 --task fixture --slug own-field-i --agent fixture >/dev/null
SEM_I=$(grep -l '^slug: own-field-i$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_I=$(grep '^orz_file: ' "$SEM_I" | cut -d' ' -f2-)

diverge_sessions_origin i
write_orz "$SESSIONS/$ORZ_BASENAME_I"
git -C "$SESSIONS" add "$ORZ_BASENAME_I"
git -C "$SESSIONS" commit -qm "own ORZ content, not yet fast-forwarded onto foreign history (I)"
republish_orz i "$ORZ_BASENAME_I"
# Duplicate the existing (otherwise valid) orz_sessions_dir line with a second,
# conflicting value -- proves the exact-match branch's len(own_matches) == 1
# guard fires on ambiguity, independent of whether either value would
# individually have matched.
printf 'orz_sessions_dir: %s\n' "$TEST_ROOT/some-other-path" >> "$SEM_I"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-own-field-i.md" <<'EOF'
---
process_id: quick-close
run_id: quick-close-own-field-i
requested_slug: own-field-i
status: completed
current_step: done
owner_session_id: session-I
results:
  gather-session-facts:
    wp: WP-484
---
EOF
{
  echo "file: inbox/agent/tasks/RUN-quick-close-own-field-i.md"
  echo "file: $ORZ_BASENAME_I"
  echo "commit: $(basename "$SESSIONS") $(git -C "$SESSIONS" rev-parse HEAD)"
} >> "$SEM_I"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-I" bash "$GUARD" close --wp WP-484 --slug own-field-i --agent fixture 2>&1); then
  echo "FAIL: close accepted a semaphore with a duplicated/conflicting orz_sessions_dir field: $CLOSE_OUT" >&2
  exit 1
else
  echo "PASS: a duplicated own_field still refuses, the legacy fallback never engages on ambiguity"
fi

# --- Scenario J (regression, must stay caught): same partially-legacy shape
# and same divergence as H, but this session's claimed ORZ content was NEVER
# actually delivered (no republish onto the diverged origin). The own-field
# fallback added for H must not turn into a blanket pass for every
# partially-legacy semaphore on a diverged checkout -- undelivered work still
# has to block close.
CLAUDE_CODE_SESSION_ID="session-J" bash "$GUARD" open --wp WP-484 --task fixture --slug own-field-j --agent fixture >/dev/null
SEM_J=$(grep -l '^slug: own-field-j$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
ORZ_BASENAME_J=$(grep '^orz_file: ' "$SEM_J" | cut -d' ' -f2-)

diverge_sessions_origin j
write_orz "$SESSIONS/$ORZ_BASENAME_J"
git -C "$SESSIONS" add "$ORZ_BASENAME_J"
git -C "$SESSIONS" commit -qm "own ORZ content, never delivered anywhere (J)"
OWN_SHA_J=$(git -C "$SESSIONS" rev-parse HEAD)
# Deliberately no republish_orz call here -- this is the point of scenario J.
strip_orz_sessions_dir "$SEM_J"

cat > "$REPO/inbox/agent/tasks/RUN-quick-close-own-field-j.md" <<EOF
---
process_id: quick-close
run_id: quick-close-own-field-j
requested_slug: own-field-j
status: completed
current_step: done
owner_session_id: session-J
results:
  gather-session-facts:
    wp: WP-484
---
EOF
{
  echo "file: inbox/agent/tasks/RUN-quick-close-own-field-j.md"
  echo "file: $ORZ_BASENAME_J"
  echo "commit: $(basename "$SESSIONS") $OWN_SHA_J"
} >> "$SEM_J"

if CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="session-J" bash "$GUARD" close --wp WP-484 --slug own-field-j --agent fixture 2>&1); then
  echo "FAIL: close accepted a partially-legacy session whose registered work was never actually delivered: $CLOSE_OUT" >&2
  exit 1
else
  echo "PASS: a partially-legacy semaphore with genuinely undelivered work still blocks close"
fi

echo "PASS: own-field legacy fallback (sessions-checkout) closes an honestly-delivered, diverged, partially-legacy session, still blocks ambiguous or undelivered claims"
