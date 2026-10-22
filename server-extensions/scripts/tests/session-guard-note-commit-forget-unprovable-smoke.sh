#!/usr/bin/env bash
# Regression for WP-484 Ф198-А (22.10, peer-session
# 2026-10-22-18-wp484-f198-forget-unprovable-retry, Claude+Kimi+Codex):
# `note-commit --forget-unprovable`.
#
# Батч-сосед одиночного `--forget` (session-guard-note-commit-forget-smoke.sh):
# сам находит все заявки семафора без независимого доказательства публикации
# и снимает их одним атомарным проходом, вместо цикла "forget по одному"
# (живой инцидент 16.10, РП-562: 9 ручных вызовов за 3 сессии). Та же
# per-claim проверка (_claimed_commits_have_publish_proof), что у одиночного
# --forget -- тот же принятый предел (сетевой сбой фолда в "unprovable", как
# и настоящее "не опубликовано", Ф209). Митигация шире охвата: список целей
# печатается в stderr ДО снятия, не после.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-commit-forget-unprovable.XXXXXX")
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

GOV="$TEST_ROOT/DS-strategy"
SES="$TEST_ROOT/MC-sessions"
WORK="$TEST_ROOT/work-repo"
mkdir -p "$GOV/inbox/WP-999" "$SES" "$WORK"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-999/WP-999.md"
for repo in "$GOV" "$SES" "$WORK"; do
  git -C "$repo" init -q
  git -C "$repo" config user.email test@test.local
  git -C "$repo" config user.name test
  echo seed > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -q -m seed
done

guard() {  # guard <subcommand> [args...]; runs from inside the sessions checkout
  (cd "$SES" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    IWE_SESSIONS_ROOT="$SES" bash "$GUARD" "$@")
}

guard open --wp WP-999 --agent fixture --slug forget-unprovable --task forget-unprovable >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }

claims() { grep -cxF "commit: work-repo $1" "$SEM" || true; }

ORIGIN=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-commit-forget-unprovable-origin.XXXXXX")
git -C "$ORIGIN" init -q --bare
git -C "$WORK" remote add origin "$ORIGIN" 2>/dev/null || git -C "$WORK" remote set-url origin "$ORIGIN"

# --- claim published to origin/main (independent proof) --------------------
echo published > "$WORK/published.txt"
git -C "$WORK" add published.txt
git -C "$WORK" commit -q -m published
SHA_PUBLISHED=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" push -q origin HEAD:refs/heads/main
guard note-commit "$SHA_PUBLISHED" --repo work-repo --agent fixture --slug forget-unprovable >/dev/null 2>&1

# --- two stray claims never delivered anywhere ------------------------------
echo stray-one > "$WORK/stray-one.txt"
git -C "$WORK" add stray-one.txt
git -C "$WORK" commit -q -m stray-one
SHA_STRAY_ONE=$(git -C "$WORK" rev-parse HEAD)
guard note-commit "$SHA_STRAY_ONE" --repo work-repo --agent fixture --slug forget-unprovable >/dev/null 2>&1

echo stray-two > "$WORK/stray-two.txt"
git -C "$WORK" add stray-two.txt
git -C "$WORK" commit -q -m stray-two
SHA_STRAY_TWO=$(git -C "$WORK" rev-parse HEAD)
guard note-commit "$SHA_STRAY_TWO" --repo work-repo --agent fixture --slug forget-unprovable >/dev/null 2>&1

check "three claims recorded before forget-unprovable" "3" \
  "$(($(claims "$SHA_PUBLISHED") + $(claims "$SHA_STRAY_ONE") + $(claims "$SHA_STRAY_TWO")))"

OUT=$(guard note-commit --forget-unprovable --repo work-repo --agent fixture --slug forget-unprovable 2>&1); RC=$?
check "forget-unprovable succeeds" "0" "$RC"
# "commit: work-repo <sha>" appears twice per removed target: once in the
# pre-action "будут сняты:" list (stderr), once in "Forgot commit: ..."
# (stdout, after the atomic rewrite) -- both are the printed trail required
# by the peer-session safeguard, not duplication to fix.
check "list printed before removal: stray one" "2" "$(grep -c "commit: work-repo $SHA_STRAY_ONE" <<<"$OUT")"
check "list printed before removal: stray two" "2" "$(grep -c "commit: work-repo $SHA_STRAY_TWO" <<<"$OUT")"
check "published claim not printed as unprovable" "0" "$(grep -c "^  commit: work-repo $SHA_PUBLISHED\$" <<<"$OUT")"
check "both stray claims removed" "0" "$(($(claims "$SHA_STRAY_ONE") + $(claims "$SHA_STRAY_TWO")))"
check "published claim kept (has independent proof)" "1" "$(claims "$SHA_PUBLISHED")"

AUDIT="$TEST_ROOT/.iwe-runtime/note-commit-forget.log"
check "audit: batch intent for stray one" "1" "$(grep -c "forget-intent.*work-repo $SHA_STRAY_ONE.*\"batch\": true" "$AUDIT" 2>/dev/null || echo 0)"
check "audit: batch done for stray two" "1" "$(grep -c "forget-done.*work-repo $SHA_STRAY_TWO.*\"batch\": true" "$AUDIT" 2>/dev/null || echo 0)"
check "no temp file left next to the semaphore" "0" "$(find "$(dirname "$SEM")" -name '.commit-forget-*' | wc -l | tr -d ' ')"

# --- positional sha rejected -------------------------------------------------
OUT=$(guard note-commit --forget-unprovable "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" --repo work-repo --agent fixture --slug forget-unprovable 2>&1); RC=$?
check "positional sha with --forget-unprovable: refused" "1" "$RC"

# --- cold review (22.10, Ф198-А): --forget and --forget-unprovable together
# must be refused, not silently resolved by whichever branch happens to run
# first -- the published claim must survive the refusal untouched.
OUT=$(guard note-commit --forget --forget-unprovable "$SHA_PUBLISHED" --repo work-repo --agent fixture --slug forget-unprovable 2>&1); RC=$?
check "--forget + --forget-unprovable together: refused" "1" "$RC"
check "--forget + --forget-unprovable together: published claim untouched" "1" "$(claims "$SHA_PUBLISHED")"

# --- nothing left to forget: no-op, exit 0 ----------------------------------
OUT=$(guard note-commit --forget-unprovable --repo work-repo --agent fixture --slug forget-unprovable 2>&1); RC=$?
check "no unprovable claims left: exit 0" "0" "$RC"
check "no unprovable claims left: no-op message" "1" "$(grep -c "ничего не снято" <<<"$OUT")"
check "published claim still kept after no-op" "1" "$(claims "$SHA_PUBLISHED")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: note-commit --forget-unprovable (batch removal, list-before-action, independent proof kept)"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
