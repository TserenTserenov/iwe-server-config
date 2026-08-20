#!/usr/bin/env bash
# Explicit contract for WP-484 Ф107, п.3 ("unfinished РП не блокируют закрытие").
#
# Pilot's direct instruction (Ф107): "Я хочу, чтобы закрытие состоялось всегда,
# даже если есть незакрытые РП. они просто перейдут на завтра." — the same
# always-run principle already fixed for Day Open in Ф105.
#
# Today this holds only DE FACTO: neither day-close-lock.sh (git-lock, SKILL.md
# step 0.6) nor day-close-mechanical.sh (the automated governance batch called
# by night-cycle-day.sh) ever reads WP-REGISTRY.md / a WP's frontmatter status /
# DayPlan checkbox state as a precondition — open РП are simply never checked,
# so nothing today CAN block on them. That is not the same as a guaranteed
# contract: a future edit could add such a check (e.g. "don't close if any P1
# is in_progress") without anyone noticing it silently reintroduces exactly the
# blocker class Ф107 was written to rule out. This fixture pins the behavior so
# a regression fails loud, not months later during a live incident like 16.08's.
#
# Two independent checks, both required:
#   1. Static — neither script's source contains a WP-status/registry read
#      wired to a blocking exit path. Cheap, catches the regression at the
#      code-review stage before it ever runs.
#   2. Behavioral — day-close-lock.sh acquire actually returns exit 0 (lock
#      acquired) against a fixture repo whose WP-REGISTRY/DayPlan carry an
#      open in_progress РП with unchecked items. day-close-mechanical.sh is
#      NOT exercised end-to-end here (session-guard.sh + ds-publish.sh pull
#      in a real remote and a session-guard semaphore lifecycle outside this
#      fixture's scope) — its static check above covers the same regression
#      class for that script.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LOCK_SCRIPT="$ROOT_DIR/scripts/day-close-lock.sh"
MECH_SCRIPT="$ROOT_DIR/DS-my-strategy/scripts/day-close-mechanical.sh"

# --- Check 1: static — no WP-status-driven blocking path in either script ---
# A single content regex would be brittle either way (false positives on
# comments, false negatives on rephrasing), so the real static guarantee is
# simpler and exhaustive instead: neither script exits non-zero anywhere
# except for the documented, purely mechanical reasons already covered by
# their own header comments (git/session-guard/publish failures) — verified
# by pinning the full accountable exit-code list below. A new exit code is
# exactly the shape a WP-status blocker would take.
STATIC_FAIL=0
LOCK_EXITS=$(grep -oE 'exit [0-9]+' "$LOCK_SCRIPT" | sort -u)
EXPECTED_LOCK_EXITS=$'exit 0\nexit 1\nexit 2\nexit 3'
if [ "$LOCK_EXITS" != "$EXPECTED_LOCK_EXITS" ]; then
  echo "FAIL: day-close-lock.sh exit codes changed ($LOCK_EXITS) — this fixture" >&2
  echo "  only knows exit 0 (lock acquired) / 1 (already closed today) / 2 (git op" >&2
  echo "  failed, retry) / 3 (someone else closing right now). A NEW exit code is" >&2
  echo "  exactly the shape a WP-status blocker would take (e.g. exit 4 = \"open" >&2
  echo "  P1 blocks close\") — if this is intentional, update this fixture's" >&2
  echo "  EXPECTED_LOCK_EXITS and confirm the new code does not gate on WP status." >&2
  STATIC_FAIL=1
fi
# Content check on BOTH scripts: today neither references WP-REGISTRY/a WP's
# inbox content at all (day-close-mechanical.sh's one WP-REGISTRY mention is
# this test's own header comment quoting it, and the script's actual header
# comment explaining it deliberately skips WP-REGISTRY updates — grepped here
# for real). A future reference to either is exactly how a status-based
# blocker would be wired in.
for script in "$LOCK_SCRIPT" "$MECH_SCRIPT"; do
  hits=$(grep -c 'WP-REGISTRY\|inbox/WP-' "$script" 2>/dev/null || true)
  if [ "${hits:-0}" -gt 1 ]; then
    echo "FAIL: $script now has $hits references to WP-REGISTRY/inbox/WP- content" >&2
    echo "  (previously had at most 1, its own explanatory comment). Confirm any" >&2
    echo "  new reference does not condition day-close on a WP's status (Ф107)." >&2
    STATIC_FAIL=1
  fi
done
if [ "$STATIC_FAIL" -ne 0 ]; then
  exit 1
fi

# --- Check 2: behavioral — acquire succeeds against an unfinished-WP fixture ---
TEST_ROOT=$(mktemp -d /private/tmp/day-close-unfinished-wp.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

git init -q --bare "$TEST_ROOT/remote.git"
git clone -q "$TEST_ROOT/remote.git" "$TEST_ROOT/fixture-repo"
(
  cd "$TEST_ROOT/fixture-repo"
  git config user.email "test@test.local"
  git config user.name "test"
  mkdir -p docs current
  cat > docs/WP-REGISTRY.md <<'EOF'
| WP | ст | P | Название |
|-----|----|----|----------|
| 900 | 🔄 | P1 | **Незакрытый тестовый РП (fixture)** |
EOF
  YESTERDAY=$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)
  cat > "current/DayPlan $YESTERDAY.md" <<EOF
- [ ] WP-900 не доделан — открытый пункт, намеренно не отмечен
EOF
  git add docs/WP-REGISTRY.md "current/DayPlan $YESTERDAY.md"
  git commit -q -m "fixture: WP-900 in_progress, DayPlan has an unchecked item"
  git push -q origin HEAD:main
)

# Real profiles on this machine export GOVERNANCE_REPO/IWE_GOVERNANCE_REPO
# globally (~/.zshrc or equivalent) — day-close-lock.sh's own fallback chain
# is `${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}`, so an inherited
# GOVERNANCE_REPO wins over the fixture's IWE_GOVERNANCE_REPO unless explicitly
# unset here. Without `env -u` this test silently operates on the REAL
# governance repo instead of the fixture (caught live while prototyping this
# fixture on this machine).
OUT=$(env -u GOVERNANCE_REPO -u IWE_GOVERNANCE_REPO \
  WORKSPACE_DIR="$TEST_ROOT" IWE_GOVERNANCE_REPO="fixture-repo" \
  bash "$LOCK_SCRIPT" acquire 2>&1)
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "FAIL: day-close-lock.sh acquire must succeed (exit 0) against a fixture" >&2
  echo "  whose WP-REGISTRY/DayPlan carry an unfinished РП — got exit $RC:" >&2
  echo "$OUT" >&2
  exit 1
fi
if ! grep -q 'Lock acquired' <<<"$OUT"; then
  echo "FAIL: expected 'Lock acquired' in output, got:" >&2
  echo "$OUT" >&2
  exit 1
fi
if ! git -C "$TEST_ROOT/fixture-repo" log -1 --format=%s | grep -q 'day-close-start:'; then
  echo "FAIL: expected a day-close-start marker commit after acquire" >&2
  exit 1
fi

echo "PASS: day-close is not blocked by an unfinished РП (Ф107 contract) —" \
     "static exit-code/content check + live day-close-lock.sh acquire against" \
     "a WP-900 in_progress + unchecked-DayPlan fixture both hold"
