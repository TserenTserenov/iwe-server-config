#!/usr/bin/env bash
# Regression for WP-561 F93 (28.11, peer session 2026-11-28-01 with Codex):
# `--repo` is read only by note-commit and note-publication. Every other
# command dropped it silently; `note-file <future path> --repo MC-sessions`
# run from the governance checkout exited 0 and claimed the path for the
# governance repository. Each refusal below is asserted by its text too, so a
# missing session or a broken fixture cannot pass for the new check.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-repo-flag.XXXXXX")
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
contains() {  # contains <name> <needle> <haystack>
  case "$3" in
    *"$2"*) echo "  ok: $1" ;;
    *) echo "  FAIL: $1 (no '$2' in: $3)"; FAILURES=$((FAILURES + 1)) ;;
  esac
}

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
# A local bare origin lets note-publication finish: it proves the commit is on origin/main.
git init -q --bare "$TEST_ROOT/origin-gov.git"
git -C "$GOV" remote add origin "$TEST_ROOT/origin-gov.git"
git -C "$GOV" push -q origin HEAD:main

guard() {  # guard <subcommand> [args...]; runs from inside the governance checkout
  (cd "$GOV" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    IWE_SESSIONS_ROOT="$SES" bash "$GUARD" "$@")
}
sem_hash() { shasum -a 256 "$SEM" | cut -d' ' -f1; }
sem_count() { find "$TEST_ROOT/.iwe-runtime/sessions" -name '*.open' 2>/dev/null | wc -l | tr -d ' '; }

guard open --wp WP-999 --agent fixture --slug repoflag --task repoflag >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }

echo "== positive control: note-file without --repo still claims =="
echo draft > "$GOV/kept.md"
guard note-file kept.md --agent fixture --slug repoflag >/dev/null 2>&1
check "plain note-file exit code" "0" "$?"
check "plain note-file claim recorded" "1" "$(grep -Fxc 'file: kept.md' "$SEM")"

echo "== the live case: future path with --repo from another checkout =="
BEFORE=$(sem_hash)
OUT=$(guard note-file 2026-11/28/x/future.md --repo MC-sessions --agent fixture --slug repoflag 2>&1); RC=$?
check "future path + --repo: refused with code 1" "1" "$RC"
contains "future path + --repo: says note-file does not take --repo" "note-file не принимает --repo" "$OUT"
contains "future path + --repo: hint names the batch form" "--paths-from0" "$OUT"
check "future path + --repo: semaphore unchanged" "$BEFORE" "$(sem_hash)"
check "future path + --repo: no claim written" "0" "$(grep -c 'future.md' "$SEM" || true)"

echo "== --forget with --repo keeps an existing claim =="
# The path is absent everywhere, so a plain --forget would withdraw it: only the new
# check keeps the claim (the previous guard dropped it and exited 0).
guard note-file gone-later.md --agent fixture --slug repoflag >/dev/null 2>&1
check "--forget fixture: claim for an absent path recorded" "1" "$(grep -Fxc 'file: gone-later.md' "$SEM")"
BEFORE=$(sem_hash)
OUT=$(guard note-file --forget gone-later.md --repo MC-sessions --agent fixture --slug repoflag 2>&1); RC=$?
check "--forget + --repo: refused with code 1" "1" "$RC"
contains "--forget + --repo: refusal is about --repo" "note-file не принимает --repo" "$OUT"
check "--forget + --repo: semaphore unchanged" "$BEFORE" "$(sem_hash)"
check "--forget + --repo: existing claim kept" "1" "$(grep -Fxc 'file: gone-later.md' "$SEM")"

echo "== batch with an empty list (used to exit 0 before picking a session) =="
: > "$TEST_ROOT/empty.lst"
OUT=$(guard note-file --paths-from0 "$TEST_ROOT/empty.lst" --repo-root "$GOV" --repo MC-sessions \
  --agent fixture --slug repoflag 2>&1); RC=$?
check "empty batch + --repo: refused with code 1" "1" "$RC"
contains "empty batch + --repo: refusal is about --repo" "note-file не принимает --repo" "$OUT"

echo "== another command: open with --repo =="
COUNT_BEFORE=$(sem_count)
OUT=$(guard open --wp WP-999 --agent fixture2 --slug other --task other --repo MC-sessions 2>&1); RC=$?
check "open + --repo: refused with code 1" "1" "$RC"
contains "open + --repo: names the two commands that read --repo" "--repo применим только к note-commit и note-publication" "$OUT"
check "open + --repo: no new session" "$COUNT_BEFORE" "$(sem_count)"

echo "== the two readers of --repo pass the new check =="
GOV_SHA=$(git -C "$GOV" rev-parse HEAD)
OUT=$(guard note-commit "$GOV_SHA" --repo DS-strategy --agent fixture --slug repoflag 2>&1)
case "$OUT" in
  *"--repo применим только"*|*"не принимает --repo"*) check "note-commit --repo not refused by the scope check" "passed" "refused" ;;
  *) check "note-commit --repo not refused by the scope check" "passed" "passed" ;;
esac
check "note-commit --repo: commit claim recorded" "1" "$(grep -c "^commit: DS-strategy $GOV_SHA" "$SEM" || true)"
OUT=$(guard note-publication "$GOV_SHA" --agent fixture --slug repoflag 2>&1)
contains "note-publication without --repo: its own refusal" "note-publication: --repo required" "$OUT"
OUT=$(guard note-publication "$GOV_SHA" --repo DS-strategy --agent fixture --slug repoflag 2>&1); RC=$?
check "note-publication --repo: exit code" "0" "$RC"
check "note-publication --repo: receipt recorded for the named repository" "1" \
  "$(grep -c "^publication_receipt_v2: .*\"repo\":\"DS-strategy\".*\"source_commit\":\"$GOV_SHA\"" "$SEM" || true)"

if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: $FAILURES check(s)"
  exit 1
fi
echo "PASSED"
