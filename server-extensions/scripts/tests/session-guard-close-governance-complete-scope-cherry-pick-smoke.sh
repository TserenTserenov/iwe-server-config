#!/usr/bin/env bash
# Regression for WP-530 Ф96 (peer-session 2026-10-14-08-wp530-governance-checkout-
# cherry-pick, Claude+Kimi+Codex, 14.10.2026): the pilot reported a suspected gap --
# the "governance checkout" role in _repo_head_has_publish_proof has no cherry-pick
# fallback (_repo_head_is_patch_equivalent is gated to "sessions checkout" only, see
# session-guard-close-sessions-patch-equivalent-head-smoke.sh scenario S). Live
# investigation (Codex read _repo_scope_has_publish_proof in full) found this claim
# imprecise: the governance checkout already has a DIFFERENT fallback --
# _repo_scope_has_publish_proof, called with own_field="governance_worktree" -- which
# does not care about the delivered commit's SHA at all, only that every claimed
# `file:`/`commit:` entry is fully covered and byte-matches the fresh origin/main.
# This test proves that fallback already rescues the honest case (direct commit into
# the shared canonical checkout, delivered via `ds-publish.sh --exact-commit`
# cherry-pick under a different SHA, complete scope registration) WITHOUT needing the
# sessions-checkout patch-equivalence fallback. Scenario S of the referenced test
# already proves the complementary case (incomplete claims must still refuse, cold
# review WP-530 Ф67) -- together they show the real differentiator is claim
# completeness, not the role name or the delivery mechanism:
#   T: governance checkout, cherry-pick delivery, COMPLETE scope claims -> close 0
#      via the scoped fallback, not the sessions-only patch-equivalence one.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-gov-scope.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

FALLBACK_MARK='patch-эквивалентны свежему origin/main (cherry-pick delivery fallback)'
SCOPE_ACCEPT_MARK='текущие файлы и commit scope этой сессии подтверждены свежим origin/main'
GOVERNANCE_REFUSAL='HEAD governance checkout не достижим из origin/main; есть неподтверждённая доставка'

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
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

SESSIONS="$TEST_ROOT/MC-sessions"
SESSIONS_ORIGIN="$TEST_ROOT/sessions-origin.git"
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

export IWE_ROOT="$TEST_ROOT"
# Explicit, not inherited: a caller shell that already exports IWE_SESSIONS_ROOT
# (ordinary on a host mid-session) silently redirects ORZ validation to the REAL
# ~/IWE/MC-sessions and this test fails with an unrelated "ORZ not committed" error
# -- found live while building this fixture (14.10.2026). The sibling test this
# file mirrors (session-guard-close-sessions-patch-equivalent-head-smoke.sh) has
# the same latent exposure; fixing that one is out of scope here.
export IWE_SESSIONS_ROOT="$SESSIONS"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

write_orz() {  # <path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
---
date: 2026-10-14
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

open_session() {  # <slug> <harness session id> -> semaphore path on stdout
  CLAUDE_CODE_SESSION_ID="$2" bash "$GUARD" open --wp WP-530 --task fixture --slug "$1" --agent fixture >/dev/null
  grep -l "^slug: $1\$" "$IWE_ROOT"/.iwe-runtime/sessions/fixture-*.open
}

orz_of() { grep '^orz_file: ' "$1" | cut -d' ' -f2-; }  # <semaphore>

close_session() {  # <slug> <harness session id> -> $CLOSE_OUT / $CLOSE_RC
  CLOSE_RC=0
  CLOSE_OUT=$(CLAUDE_CODE_SESSION_ID="$2" bash "$GUARD" close --wp WP-530 --slug "$1" --agent fixture 2>&1) || CLOSE_RC=$?
}

# --- T: direct commit into the (fixture) canonical governance checkout, no
# worktree/isolation, delivered to origin/main as a cherry-pick under another
# SHA, scope claims cover every path the own commit touched.
SLUG=gov-complete-scope-t
SEM_T=$(open_session "$SLUG" session-T)
ORZ_T=$(orz_of "$SEM_T")
write_orz "$SESSIONS/$ORZ_T"
git -C "$SESSIONS" add "$ORZ_T"
git -C "$SESSIONS" commit -qm "own ORZ (T)"
git -C "$SESSIONS" push -q origin HEAD:main

mkdir -p "$REPO/inbox/WP-530"
echo "governance note T" > "$REPO/inbox/WP-530/t-note.md"
cat > "$REPO/inbox/agent/tasks/RUN-quick-close-$SLUG.md" <<EOF
---
process_id: quick-close
run_id: quick-close-$SLUG
requested_slug: $SLUG
status: completed
current_step: done
owner_session_id: session-T
results:
  gather-session-facts:
    wp: WP-530
---
EOF
git -C "$REPO" add inbox/WP-530/t-note.md "inbox/agent/tasks/RUN-quick-close-$SLUG.md"
git -C "$REPO" commit -qm "own governance work (T)"
OWN_T=$(git -C "$REPO" rev-parse HEAD)

# Another session advances origin/main in the meantime (routine concurrency on a
# shared canonical checkout), then our own change lands via cherry-pick delivery
# (what `ds-publish.sh --exact-commit` does) under a brand-new SHA.
FOREIGN="$TEST_ROOT/foreign"
git clone -q "$ORIGIN" "$FOREIGN"
git -C "$FOREIGN" config user.email foreign@test
git -C "$FOREIGN" config user.name foreign
echo "unrelated foreign work" > "$FOREIGN/foreign.txt"
git -C "$FOREIGN" add foreign.txt
git -C "$FOREIGN" commit -qm "foreign session advances origin"
git -C "$FOREIGN" push -q origin HEAD:main

# Literal cherry-pick (not a hand-copied duplicate file) from a fresh clone of
# origin/main, onto which the foreign commit above already landed -- the exact
# delivery mechanism `ds-publish.sh --exact-commit` uses, so the delivered SHA
# is a real `git cherry-pick` result, not a content coincidence (cold-review,
# Codex, same session).
REPUB="$TEST_ROOT/republish-t"
git clone -q "$ORIGIN" "$REPUB"
git -C "$REPUB" config user.email republish@test
git -C "$REPUB" config user.name republish
git -C "$REPUB" fetch -q "$REPO" "$OWN_T"
git -C "$REPUB" cherry-pick FETCH_HEAD >/dev/null
git -C "$REPUB" push -q origin HEAD:main
DELIVERED_T=$(git -C "$REPUB" rev-parse HEAD)
[ "$DELIVERED_T" != "$OWN_T" ] \
  || fail "T: fixture setup -- cherry-pick landed under the SAME sha as the local commit, delivery is not actually under a different SHA"

git -C "$REPO" fetch -q origin main
git -C "$REPO" merge-base --is-ancestor HEAD origin/main 2>/dev/null \
  && fail "T: fixture setup -- local HEAD is still an ancestor of origin/main, divergence not achieved"

# Complete claim: every path the own commit touched, plus the exact commit sha.
{
  echo "file: inbox/agent/tasks/RUN-quick-close-$SLUG.md"
  echo "file: $ORZ_T"
  echo "file: inbox/WP-530/t-note.md"
  echo "commit: $(basename "$REPO") $OWN_T"
} >> "$SEM_T"

close_session "$SLUG" session-T; OUT_T=$CLOSE_OUT
[ "$CLOSE_RC" -eq 0 ] || fail "T: close refused an honestly delivered governance session with complete scope claims (rc $CLOSE_RC): $OUT_T"
grep -qF "$SCOPE_ACCEPT_MARK" <<<"$OUT_T" \
  || fail "T: close passed but not through the scoped publish-proof fallback: $OUT_T"
grep -qF "$FALLBACK_MARK" <<<"$OUT_T" \
  && fail "T: the sessions-only patch-equivalence fallback must stay gated away from governance: $OUT_T"
grep -qF "$GOVERNANCE_REFUSAL" <<<"$OUT_T" \
  && fail "T: governance ancestry refusal should not surface once the scoped fallback accepted: $OUT_T"
echo "PASS: T -- a direct commit into the shared governance checkout, delivered via cherry-pick under another SHA, closes through the scoped publish-proof fallback when scope claims are complete"

echo "OK: session-guard governance-checkout complete-scope cherry-pick delivery (T)"
