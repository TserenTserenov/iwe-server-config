#!/usr/bin/env bash
# WP-484 Ф274: a temporary IWE_ROOT must not write into an inherited non-temporary
# IWE_SESSIONS_ROOT. Exercises the real guard end to end: `open` creates the report
# scaffold, so the observable result is where that file landed.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../session-guard.sh"

SANDBOX="$(mktemp -d)"
LIVE="$(mktemp -d "$HOME/.sessions-root-smoke.XXXXXX")"  # outside every temp dir, like the real one
trap 'rm -rf "$SANDBOX" "$LIVE"' EXIT
git init -q "$LIVE"

fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

make_root() {
  local gov="$1/DS-strategy"
  mkdir -p "$gov/inbox/WP-1"
  git init -q "$gov"
  git -C "$gov" config user.name fixture
  git -C "$gov" config user.email fixture@example.invalid
  printf -- '---\nwp: 1\nstatus: in_progress\n---\n' > "$gov/inbox/WP-1/WP-1.md"
  git -C "$gov" add inbox
  git -C "$gov" commit -qm init
}

open_session() { # root sessions_root slug
  (cd "$1/DS-strategy" && IWE_ROOT="$1" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    IWE_SESSIONS_ROOT="$2" IWE_SESSIONS_SPLIT_LOG="$SANDBOX/split.log" IWE_AGENT=fixture \
    CLAUDE_CODE_SESSION_ID="smoke-$3" \
    bash "$GUARD" open --wp WP-1 --agent fixture --task smoke --slug "$3" 2>&1)
}

# 1. The leak: temp root + inherited live value. Nothing reaches the live repository.
ROOT1="$SANDBOX/one"; make_root "$ROOT1"
OUT1="$(open_session "$ROOT1" "$LIVE" leak || true)"
check "live repository stays clean" '[ -z "$(git -C "$LIVE" status --porcelain)" ]'
check "drop is announced" 'grep -q SESSIONS_SPLIT_BLOCKED <<<"$OUT1"'
check "positive control: the guard logged the drop" '[ -s "$SANDBOX/split.log" ]'
check "semaphore still created in the sandbox" 'ls "$ROOT1"/.iwe-runtime/sessions/*.open >/dev/null 2>&1'
check "report written inside the sandbox" 'find "$ROOT1" -name "*-leak.md" | grep -q .'

# 2. A deliberate sandbox sessions root is honored, not dropped.
ROOT2="$SANDBOX/two"; make_root "$ROOT2"
MC2="$SANDBOX/mc2"; git init -q "$MC2"
OUT2="$(open_session "$ROOT2" "$MC2" kept || true)"
check "temp sessions root is honored" 'find "$MC2" -name "*-kept.md" | grep -q .'
check "no drop announced for it" '! grep -q SESSIONS_SPLIT_BLOCKED <<<"$OUT2"'

# 3. Production shape: non-temp root keeps its non-temp sessions root. The helper is
# extracted rather than run through `open`, which needs a full live layout.
HELPERS="$(sed -n '/^_iwe_physical_path() {/,/^iwe_drop_inherited_live_sessions_root$/p' "$GUARD" | sed '$d')"
check_keep() { # iwe_root sessions_root expected
  local result
  result="$(IWE_ROOT="$1" IWE_SESSIONS_ROOT="$2" bash -c "$HELPERS"$'\niwe_drop_inherited_live_sessions_root 2>/dev/null; printf %s "${IWE_SESSIONS_ROOT:-}"')"
  [ "$result" = "$3" ]
}
check "production pair is untouched" 'check_keep "$LIVE" "$LIVE/MC-sessions" "$LIVE/MC-sessions"'
check "temp root drops a non-temp value" 'check_keep "$SANDBOX/x" "$LIVE" ""'
check "trailing slash and missing dirs still count as temp" 'check_keep "$SANDBOX/no/such/dir/" "$LIVE" ""'
check "symlinked temp path is resolved" 'ln -s "$SANDBOX" "$LIVE/link" && check_keep "$LIVE/link/y" "$LIVE" ""'

unreachable_tmpdir_still_drops() {
  local rc=0
  mkdir -p "$SANDBOX/noaccess/sub"
  chmod 000 "$SANDBOX/noaccess"
  TMPDIR="$SANDBOX/noaccess/sub" check_keep "$SANDBOX/x" "$LIVE" "" || rc=$?
  chmod 700 "$SANDBOX/noaccess"
  return "$rc"
}
check "unreachable TMPDIR does not disable the drop" unreachable_tmpdir_still_drops

# 4. The canary itself: every way a test can dirty the repository or fail must show.
CANARY="$HERE/sessions-leak-canary.sh"
FX="$SANDBOX/fx"; mkdir -p "$FX"
printf '%s\n' 'touch "$IWE_SESSIONS_ROOT/x"' > "$FX/plain.sh"
printf '%s\n' 'git -C "$IWE_SESSIONS_ROOT" -c user.name=f -c user.email=f@e.invalid commit -q --allow-empty -m leak' > "$FX/committed.sh"
printf '%s\n' 'exit 3' > "$FX/failing.sh"
printf '%s\n' 'exit 0' > "$FX/clean.sh"
canary_rc() { local rc=0; IWE_ROOT="$LIVE" bash "$CANARY" "$FX/$1.sh" >/dev/null 2>&1 || rc=$?; [ "$rc" = "$2" ]; }
check "canary: file leak gives exit 1" 'canary_rc plain 1'
check "canary: committed leak gives exit 1" 'canary_rc committed 1'
check "canary: failing test gives exit 3" 'canary_rc failing 3'
check "canary: clean test gives exit 0" 'canary_rc clean 0'
unusable_root_rc() { local rc=0; IWE_ROOT=/nonexistent/x bash "$CANARY" "$FX/clean.sh" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ]; }
check "canary: unusable root gives exit 2" unusable_root_rc

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAIL"; exit 1; }
