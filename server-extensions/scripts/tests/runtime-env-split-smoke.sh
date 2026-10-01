#!/usr/bin/env bash
# runtime-env-split-smoke.sh -- WP-530 Ф75 (01.10.2026, peer-session 2026-10-01-11-wp530-f75-runtime-env-split).
# IWE_RUNTIME is the HOST NAME (DP.IWE.011 §C: claude-code|headless|hermes|bot), never a path; the runtime
# DIRECTORY is IWE_RUNTIME_DIR. .claude/settings.json sets IWE_RUNTIME=claude-code, so every reader that used
# $IWE_RUNTIME as a directory silently looked into "claude-code/..." relative to its cwd. This smoke checks the
# root-repo readers fixed in Ф75 inside a throwaway sandbox (own HOME, WORKSPACE_DIR, no live paths):
#   - .claude/lib/iwe-env-bootstrap.sh   exports IWE_RUNTIME_DIR; IWE_RUNTIME stays a host name when one is set
#   - .claude/hooks/protocol-stop-gate.sh  fail-closed branch reads the obligation file from IWE_RUNTIME_DIR
#   - scripts/canon-reconcile-published.sh  runtime directory resolution (host name ignored, absolute and normalized, ignored when
#                                          inside the repository) without creating or removing anything
# Usage: runtime-env-split-smoke.sh [<repo-root>]   (default: the repository that contains this file)
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
BOOT="$ROOT/.claude/lib/iwe-env-bootstrap.sh"
HOOK="$ROOT/.claude/hooks/protocol-stop-gate.sh"
[ -f "$BOOT" ] && [ -f "$HOOK" ] || { echo "FAIL: bootstrap or stop-gate hook not found under $ROOT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required by the stop-gate hook" >&2; exit 0; }
T=$(mktemp -d "$(printf '%s' "${TMPDIR:-/tmp}" | sed 's#/*$##')/runtime-env-split.XXXXXX"); trap 'rm -rf "$T"' EXIT
WS="$T/ws"; mkdir -p "$WS" "$T/home"
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }

# run the bootstrap in a clean environment and print "<IWE_RUNTIME>|<IWE_RUNTIME_DIR>"
boot() {  # <env assignments...>
  env -i HOME="$T/home" PATH="$PATH" WORKSPACE_DIR="$WS" "$@" \
    bash -c 'source "'"$BOOT"'" >/dev/null 2>&1; printf "%s|%s" "${IWE_RUNTIME-<unset>}" "${IWE_RUNTIME_DIR-<unset>}"'
}

echo "scenario B1: neither variable set -> both default to the workspace runtime directory"
assert "$(boot)" "$WS/.iwe-runtime|$WS/.iwe-runtime" "IWE_RUNTIME and IWE_RUNTIME_DIR default to \$WORKSPACE_DIR/.iwe-runtime"

echo "scenario B2: host name set (Claude Code) -> stays a host name, directory is separate"
assert "$(boot IWE_RUNTIME=claude-code)" "claude-code|$WS/.iwe-runtime" "IWE_RUNTIME=claude-code kept; IWE_RUNTIME_DIR defaulted"

echo "scenario B3: only the directory variable set -> the legacy name follows it (transitional)"
assert "$(boot IWE_RUNTIME_DIR=/x/rt)" "/x/rt|/x/rt" "IWE_RUNTIME follows IWE_RUNTIME_DIR when no host name is set"

echo "scenario B4: both set -> neither is touched"
assert "$(boot IWE_RUNTIME=headless IWE_RUNTIME_DIR=/x/rt)" "headless|/x/rt" "both values kept"

echo "scenario B5: legacy caller exports IWE_RUNTIME as an existing ABSOLUTE directory -> IWE_RUNTIME_DIR follows it (no silent split)"
mkdir -p "$T/legacy-rt"
assert "$(boot IWE_RUNTIME="$T/legacy-rt")" "$T/legacy-rt|$T/legacy-rt" "both names on the legacy directory"

echo "scenario B6: IWE_RUNTIME is an absolute path that is not a directory -> not taken for a directory"
assert "$(boot IWE_RUNTIME=/nonexistent/abs)" "/nonexistent/abs|$WS/.iwe-runtime" "IWE_RUNTIME_DIR defaulted, IWE_RUNTIME kept"

# --- stop-gate: fail-closed branch (close_obligation.py unusable) with an armed obligation file
echo "scenario S1: stop-gate fail-closed branch finds the obligation file under IWE_RUNTIME_DIR while IWE_RUNTIME is a host name"
mkdir -p "$WS/DS-my-strategy/scripts"
printf 'import sys\nsys.exit(1)\n' > "$WS/DS-my-strategy/scripts/close_obligation.py"
SID="smoke-f75-$$"
HASH=$(printf '%s' "$SID" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:32])')
TRANSCRIPT="$T/transcript.jsonl"; echo '{}' > "$TRANSCRIPT"
gate() {  # <runtime-dir-env...> -> hook stdout
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SID" "$TRANSCRIPT" \
    | env -i HOME="$T/home" PATH="$PATH" WORKSPACE_DIR="$WS" IWE_GOVERNANCE_REPO=DS-my-strategy CLAUDE_PROJECT_DIR="$WS" "$@" bash "$HOOK" 2>/dev/null
}
mkdir -p "$T/rtd/close-obligation"
out=$(gate IWE_RUNTIME=claude-code IWE_RUNTIME_DIR="$T/rtd")
assert "$(printf '%s' "$out" | jq -r '.decision // "none"' 2>/dev/null)" "none" "no obligation file -> no block"
echo '{}' > "$T/rtd/close-obligation/$HASH.json"
out=$(gate IWE_RUNTIME=claude-code IWE_RUNTIME_DIR="$T/rtd")
assert "$(printf '%s' "$out" | jq -r '.decision // "none"' 2>/dev/null)" "block" "armed obligation under IWE_RUNTIME_DIR blocks although IWE_RUNTIME=claude-code"
rm -rf "$T/rtd"

echo "scenario S2: IWE_RUNTIME_DIR unset -> obligation file read from the workspace runtime directory"
mkdir -p "$WS/.iwe-runtime/close-obligation"; echo '{}' > "$WS/.iwe-runtime/close-obligation/$HASH.json"
out=$(gate IWE_RUNTIME=claude-code)
assert "$(printf '%s' "$out" | jq -r '.decision // "none"' 2>/dev/null)" "block" "default directory \$WORKSPACE_DIR/.iwe-runtime is used"

# --- canon-reconcile-published.sh: runtime directory resolution (exits before any git work on a bad directory)
GUARD="$ROOT/scripts/canon-reconcile-published.sh"
if [ -f "$GUARD" ]; then
  GR="$T/g/repo"; mkdir -p "$T/g"; git init -q -b main "$GR"
  printf '.rt/\n.trk/\n' > "$GR/.gitignore"; mkdir -p "$GR/.trk"; echo tracked > "$GR/.trk/f.txt"
  git -C "$GR" add .gitignore; git -C "$GR" add -f .trk/f.txt
  GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid git -C "$GR" commit -q -m base
  guard() {  # <env assignments...> -> "<exit>|<stderr>"
    local err rc
    err=$(cd "$T" && env -i HOME="$T/home" PATH="$PATH" "$@" bash "$GUARD" "$GR" main 2>&1 >/dev/null); rc=$?
    printf '%s|%s' "$rc" "$err"
  }
  has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

  echo "scenario G1: a relative runtime dir (the host name taken for a path) is refused"
  out=$(guard IWE_RUNTIME_DIR=claude-code); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "must be absolute")" "yes" "message says: must be absolute"

  echo "scenario G2: a pre-existing EMPTY directory inside the repository that is not ignored is refused and NOT removed"
  mkdir -p "$GR/scratch"
  out=$(guard IWE_RUNTIME_DIR="$GR/scratch"); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "is not ignored")" "yes" "message says: its log is not ignored"
  assert "$([ -d "$GR/scratch" ] && echo kept || echo removed)" "kept" "the pre-existing directory is still there"

  echo "scenario G3: a missing non-ignored path inside the repository is refused and nothing is created"
  out=$(guard IWE_RUNTIME_DIR="$GR/a/b/runtime"); assert "${out%%|*}" "2" "exit 2"
  assert "$([ -e "$GR/a" ] && echo created || echo untouched)" "untouched" "no parent directory was created"

  echo "scenario G4: an ignored (missing) path inside the repository passes the directory check"
  out=$(guard IWE_RUNTIME_DIR="$GR/.rt"); assert "$(has "$out" "git fetch origin main failed")" "yes" "the directory check passed and the guard went on to its next stage (no origin in the sandbox)"; assert "$(has "$out" "runtime dir")" "no" "no runtime-dir refusal"

  echo "scenario G5: a path with '..' components is refused"
  out=$(guard IWE_RUNTIME_DIR="$T/x/../y"); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "must not contain")" "yes" "message says: must not contain .. components"

  echo "scenario G6: an ignored directory that holds tracked files is refused"
  out=$(guard IWE_RUNTIME_DIR="$GR/.trk"); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "tracked files")" "yes" "message says: tracked files"

  echo "scenario G7: legacy absolute IWE_RUNTIME (existing directory) is accepted with a notice"
  mkdir -p "$T/legacy-rt2"
  out=$(guard IWE_RUNTIME="$T/legacy-rt2"); assert "$(has "$out" "legacy caller")" "yes" "notice printed"; assert "$(has "$out" "git fetch origin main failed")" "yes" "the guard went on to its next stage"

  echo "scenario G8: a symlink to an ignored directory inside the repository resolves and passes"
  mkdir -p "$GR/.rt"; ln -s "$GR/.rt" "$T/link-rt"
  out=$(guard IWE_RUNTIME_DIR="$T/link-rt"); assert "$(has "$out" "git fetch origin main failed")" "yes" "the link was resolved, the directory check passed and the guard went on"; assert "$(has "$out" "cannot resolve")" "no" "the link was not reported as unresolvable"

  echo "scenario G9: a symlink to a NON-ignored directory inside the repository is resolved and refused (the link target decides, not the link location)"
  ln -s "$GR/scratch" "$T/link-scratch"
  out=$(guard IWE_RUNTIME_DIR="$T/link-scratch"); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "is not ignored")" "yes" "message says: its log is not ignored"

  echo "scenario G10: a dangling symlink is refused instead of being taken for an outside path"
  ln -s "$GR/missing-target" "$T/link-dangling"
  out=$(guard IWE_RUNTIME_DIR="$T/link-dangling"); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "cannot resolve")" "yes" "message says: cannot resolve"
  out=$(guard IWE_RUNTIME_DIR="$T/link-dangling/"); assert "${out%%|*}" "2" "exit 2 with one trailing slash"; assert "$(has "$out" "cannot resolve")" "yes" "message says: cannot resolve (one trailing slash)"
  out=$(guard IWE_RUNTIME_DIR="$T/link-dangling///"); assert "${out%%|*}" "2" "exit 2 with several trailing slashes"; assert "$(has "$out" "cannot resolve")" "yes" "message says: cannot resolve (several trailing slashes)"
  assert "$([ -e "$GR/missing-target" ] && echo created || echo untouched)" "untouched" "the link target was not created"

  echo "scenario G11: an ignore rule for some other name does not vouch for the log file"
  printf 'only-probe/.runtime-dir-probe\n' >> "$GR/.gitignore"
  out=$(guard IWE_RUNTIME_DIR="$GR/only-probe"); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "is not ignored")" "yes" "message says: its log is not ignored"

  echo "scenario G12: directory contents ignored but the log un-ignored by a negated rule is refused"
  printf 'unignored-log/*\n!unignored-log/canon-reconcile-published.log\n' >> "$GR/.gitignore"
  out=$(guard IWE_RUNTIME_DIR="$GR/unignored-log"); assert "${out%%|*}" "2" "exit 2"; assert "$(has "$out" "is not ignored")" "yes" "message says: its log is not ignored"
else
  echo "scenario G*: skipped (no scripts/canon-reconcile-published.sh under $ROOT)"
fi

[ "$fails" -eq 0 ] && { echo "PASS: all scenarios"; exit 0; } || { echo "FAIL: $fails assertion(s)"; exit 1; }
