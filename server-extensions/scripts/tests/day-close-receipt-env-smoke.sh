#!/usr/bin/env bash
# WP-539 F21 B5: the day-close skill must hand the publisher an agent and the housekeeping
# session id, but only after the day commit is claimed; otherwise it publishes without them.
# The block between BEGIN-RECEIPT-ENV and END-RECEIPT-ENV is extracted from the skill text
# and run against a stub guard, so the test follows the skill and not a copy of it.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT/.claude/skills/day-close/SKILL.md"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAIL=0

BLOCK=$(awk '/^# BEGIN-RECEIPT-ENV/{f=1} f{print} /^# END-RECEIPT-ENV/{f=0}' "$SKILL")
[ -n "$BLOCK" ] || { echo "FAIL: markers BEGIN/END-RECEIPT-ENV not found in $SKILL"; exit 1; }

mkdir -p "$T/root/.iwe-runtime/sessions" "$T/scripts" "$T/DS-my-strategy"
git -C "$T/DS-my-strategy" init -q -b main
git -C "$T/DS-my-strategy" -c user.email=t@example.test -c user.name=t commit -q --allow-empty -m x
SHA=$(git -C "$T/DS-my-strategy" rev-parse HEAD)

# Stub guard: records its arguments and the agent it saw; exits with $STUB_RC.
cat > "$T/scripts/session-guard.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|agent=%s\n' "$*" "${IWE_AGENT:-}" >> "$STUB_LOG"
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/scripts/session-guard.sh"

run_block() {  # <stub rc>; prints "ENV=<array>" then stderr on the next lines
  (
    cd "$T/DS-my-strategy" || exit 9
    export IWE_ROOT="$T/root" IWE_SCRIPTS="$T/scripts" STUB_LOG="$T/log" STUB_RC="$1"
    # shellcheck disable=SC2034  # read by the extracted skill block
    DC_SHA="$SHA"
    eval "$BLOCK"
    echo "ENV=${DC_RECEIPT_ENV[*]:-}"
  ) 2>&1
}
expect() {  # <label> <output> <needle> <yes|no>
  case "$2" in
    *"$3"*) [ "$4" = yes ] || { echo "FAIL: $1: unexpected '$3' in: $2"; FAIL=1; } ;;
    *) [ "$4" = no ] || { echo "FAIL: $1: missing '$3' in: $2"; FAIL=1; } ;;
  esac
}

# 1. Semaphore present, claim accepted: agent + housekeeping id exported, commit claimed by slug.
: > "$T/root/.iwe-runtime/sessions/claude-code-housekeeping-day-close.open"
: > "$T/log"
OUT=$(run_block 0)
expect "claimed" "$OUT" "ENV=IWE_AGENT=claude-code IWE_PUBLICATION_SESSION_ID=housekeeping-day-close" yes
expect "claimed" "$OUT" "WARN" no
LOG=$(cat "$T/log")
expect "claimed: note-commit args" "$LOG" "note-commit $SHA --repo DS-my-strategy --agent claude-code --slug day-close|agent=claude-code" yes

# 2. Semaphore present, claim refused: no env, loud warning (the failure is not masked).
: > "$T/log"
OUT=$(run_block 1)
printf '%s\n' "$OUT" | grep -qx 'ENV=' || { echo "FAIL: claim refused: ENV array is not empty: $OUT"; FAIL=1; }
expect "claim refused" "$OUT" "IWE_AGENT" no
expect "claim refused" "$OUT" "WARN: коммит дня не заявлен" yes

# 3. No semaphore: the guard is not even called, no env, warning.
rm -f "$T/root/.iwe-runtime/sessions/claude-code-housekeeping-day-close.open"
: > "$T/log"
OUT=$(run_block 0)
expect "no semaphore" "$OUT" "IWE_AGENT" no
expect "no semaphore" "$OUT" "WARN: коммит дня не заявлен" yes
[ ! -s "$T/log" ] || { echo "FAIL: no semaphore: guard was called: $(cat "$T/log")"; FAIL=1; }

# 4. Guard missing (template install without it): no env, warning, no crash.
: > "$T/root/.iwe-runtime/sessions/claude-code-housekeeping-day-close.open"
rm -f "$T/scripts/session-guard.sh"
OUT=$(run_block 0)
expect "no guard" "$OUT" "IWE_AGENT" no
expect "no guard" "$OUT" "WARN: коммит дня не заявлен" yes

# 4b. Repository name: an isolated worktree reports the owner repo, the IWE root reports iwe-root
# (the same naming isolate-push.sh uses when it records the receipt).
cat > "$T/scripts/session-guard.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|agent=%s\n' "$*" "${IWE_AGENT:-}" >> "$STUB_LOG"
exit "${STUB_RC:-0}"
STUB
git -C "$T/DS-my-strategy" worktree add -q -b iso "$T/iso-copy"
: > "$T/log"
OUT=$(cd "$T/iso-copy" && IWE_ROOT="$T/root" IWE_SCRIPTS="$T/scripts" STUB_LOG="$T/log" STUB_RC=0 DC_SHA="$SHA" \
  bash -c "$BLOCK"$'\n'"echo ENV=\${DC_RECEIPT_ENV[*]:-}" 2>&1)
expect "worktree" "$OUT" "ENV=IWE_AGENT=claude-code IWE_PUBLICATION_SESSION_ID=housekeeping-day-close" yes
expect "worktree repo name" "$(cat "$T/log")" "--repo DS-my-strategy " yes

mkdir -p "$T/rootrepo/.iwe-runtime/sessions"
: > "$T/rootrepo/.iwe-runtime/sessions/claude-code-housekeeping-day-close.open"
git -C "$T/rootrepo" init -q -b main
git -C "$T/rootrepo" -c user.email=t@example.test -c user.name=t commit -q --allow-empty -m x
: > "$T/log"
OUT=$(cd "$T/rootrepo" && IWE_ROOT="$T/rootrepo" IWE_SCRIPTS="$T/scripts" STUB_LOG="$T/log" STUB_RC=0 DC_SHA="$SHA" \
  bash -c "$BLOCK"$'\n'"echo ENV=\${DC_RECEIPT_ENV[*]:-}" 2>&1)
expect "root repo name" "$(cat "$T/log")" "--repo iwe-root " yes

# 5. The publisher call in the skill really takes the array (a fix that is not wired in is no fix).
# shellcheck disable=SC2016  # the pattern is literal text, not an expansion
grep -q 'env ${DC_RECEIPT_ENV\[@\]+"${DC_RECEIPT_ENV\[@\]}"} bash scripts/ds-publish.sh' "$SKILL" \
  || { echo "FAIL: ds-publish.sh call in the skill does not use DC_RECEIPT_ENV"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "PASS: day-close receipt env" || exit 1
