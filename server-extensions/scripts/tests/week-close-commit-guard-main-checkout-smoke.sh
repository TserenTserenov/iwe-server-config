#!/usr/bin/env bash
# week-close-commit-guard-main-checkout-smoke.sh -- WP-530 Ф150 (б).
#
# In the main DS-my-strategy checkout week-close-commit-guard.sh must not pull,
# stage, commit or push there: it commits in a temporary linked worktree,
# publishes through ds-publish.sh, writes the published version into files that
# still hold the committed bytes, and leaves the fast-forward to the sync. The
# publisher is a stub; the sync stub runs the real dirty-ff-admission.py steps
# (admit, put-aside, merge, settle) the way tsekh1-git-sync.sh does. Every
# scenario asserts what reached the bare origin and what the main checkout's
# branch, index and files look like afterwards.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/../week-close-commit-guard.sh"
DS_LIB="${IWE_DS_LIB_TEST_SOURCE:-$HOME/IWE/DS-my-strategy/scripts/lib}"
SYNC_REQUEST="$DS_LIB/canon-sync-request.sh"
ADMISSION="$DS_LIB/dirty-ff-admission.py"
[ -f "$GUARD" ] && [ -f "$SYNC_REQUEST" ] && [ -f "$ADMISSION" ] \
  || { echo "FAIL: guard, canon-sync-request.sh or dirty-ff-admission.py not found (IWE_DS_LIB_TEST_SOURCE)"; exit 1; }
grep -q 'put-aside' "$ADMISSION" || { echo "FAIL: $ADMISSION predates put-aside (WP-530 Ф150)"; exit 1; }
# Fixture setup and the stubs use the system git: on tsekh-1
# ~/.iwe-runtime/bin/git blocks add/commit/merge in any main DS-my-strategy
# checkout, sandboxes included. The guard itself runs with the original PATH,
# wrapper and all, so its main-checkout path is tested as it runs in production.
GUARD_PATH="$PATH"
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.iwe-runtime/bin$' | paste -sd: -)
REAL_GIT=$(command -v git)
export PATH REAL_GIT ADMISSION
WRAPPED=no
[ "$(PATH="$GUARD_PATH" command -v git)" = "$REAL_GIT" ] || WRAPPED=yes
echo "guard runs through the git wrapper: $WRAPPED"
if [ -x "$HOME/.iwe-runtime/bin/git" ] && [ "$WRAPPED" != yes ]; then
  echo "FAIL: the git wrapper is installed but the guard would bypass it"; exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
assert() {
  if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails + 1)); fi
}

# count: a line count without padding. BSD wc on macOS right-aligns the
# number ("       0"), which never equals "0" in assert.
count() { wc -l | tr -d ' '; }

# sandbox <name> <origin-basename>: $IWE/DS-my-strategy cloned from a bare repo.
sandbox() {
  local name="$1" origin_name="$2"
  IWE="$T/$name/IWE"
  BARE="$T/$name/$origin_name.git"
  REPO="$IWE/DS-my-strategy"
  mkdir -p "$IWE/.claude/state" "$IWE/scripts/lib"
  cp "$HERE/../lib/sync-owned-canon.sh" "$IWE/scripts/lib/"
  git init -q --bare -b main "$BARE"
  git clone -q "$BARE" "$REPO" 2>/dev/null
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/scripts/lib" "$REPO/current"
  cp "$SYNC_REQUEST" "$REPO/scripts/lib/"
  # Stub publisher: cherry-picks the commit onto a fresh origin tip from a
  # temporary worktree, the way ds-publish.sh does; STUB_PUBLISH_RC fails it.
  cat > "$REPO/scripts/ds-publish.sh" <<'EOF'
#!/usr/bin/env bash
repo="$1"; shift 2
commit=""
while [ "$#" -gt 0 ]; do [ "$1" = --from-commit ] && commit="$2"; shift; done
echo "$commit" >> "$repo/../publish.calls"
[ "${STUB_PUBLISH_RC:-0}" = 0 ] || exit "$STUB_PUBLISH_RC"
tmp=$(mktemp -d)
"$REAL_GIT" -C "$repo" fetch -q origin main
"$REAL_GIT" -C "$repo" worktree add -q --detach "$tmp/wt" origin/main
"$REAL_GIT" -C "$tmp/wt" -c user.email=t@t -c user.name=t cherry-pick "$commit" >/dev/null || exit 22
"$REAL_GIT" -C "$tmp/wt" push -q origin HEAD:main
"$REAL_GIT" -C "$repo" worktree remove --force "$tmp/wt"
[ -z "${STUB_EDIT_AFTER:-}" ] || echo "edited after publication" >> "$repo/$STUB_EDIT_AFTER"
exit 0
EOF
  # Stub sync: the dirty fast-forward of tsekh1-git-sync.sh with the real helper.
  cat > "$REPO/scripts/tsekh1-git-sync.sh" <<'EOF'
#!/usr/bin/env bash
repo="$IWE_ROOT/DS-my-strategy"
report="$IWE_ROOT/sync-report.json"
echo "$*" >> "$IWE_ROOT/sync.calls"
"$REAL_GIT" -C "$repo" fetch -q origin main
up=$("$REAL_GIT" -C "$repo" rev-parse origin/main)
python3 "$ADMISSION" admit "$repo" "$("$REAL_GIT" -C "$repo" rev-parse HEAD)" "$up" "$report" || exit 1
python3 "$ADMISSION" put-aside "$repo" "$report" || exit 1
if ! "$REAL_GIT" -C "$repo" merge -q --ff-only --no-autostash --no-overwrite-ignore "$up"; then
  python3 "$ADMISSION" put-back "$repo"; exit 1
fi
python3 "$ADMISSION" settle "$repo"
EOF
  printf 'a\nb\nc\nd\ne\n' > "$REPO/current/plan.md"
  echo keep > "$REPO/current/keep.md"
  echo old > "$REPO/current/gone.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm init
  git -C "$REPO" push -q origin main
  : > "$IWE/publish.calls"
  : > "$IWE/sync.calls"
}

# advance_origin <path> <content>: someone else publishes a file.
advance_origin() {
  local other="$T/other-$RANDOM"
  git clone -q "$BARE" "$other"
  mkdir -p "$other/$(dirname "$1")"
  printf '%b' "$2" > "$other/$1"
  git -C "$other" add -- "$1"
  git -C "$other" -c user.email=t@t -c user.name=t commit -qm "other: $1"
  git -C "$other" push -q origin main
}

run_guard() { (cd "$REPO" && PATH="$RACE_BIN:${GUARD_PATH_OVERRIDE:-$GUARD_PATH}" IWE_ROOT="$IWE" bash "$GUARD" "$REPO" "week-close: test" "$@") >"$T/out" 2>&1; echo $?; }
run_sync() { IWE_ROOT="$IWE" bash "$REPO/scripts/tsekh1-git-sync.sh" >"$T/sync.out" 2>&1; echo $?; }

# Racing writers. mv: recreates the source path right after the guard moves it
# aside (STUB_RACE). ln: writes the target first (STUB_LATE_RACE).
RACE_BIN="$T/race-bin"
mkdir -p "$RACE_BIN"
cat > "$RACE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
"$(PATH=$(printf '%s' "$PATH" | sed "s#^$RACE_BIN_DIR:##") command -v mv)" "$@" || exit
src="${*: -2:1}"
if [ -n "${STUB_RACE:-}" ] && [ "${src%"$STUB_RACE"}" != "$src" ] && [ ! -e "$src" ]; then
  echo "racing edit" > "$src"
fi
EOF
cat > "$RACE_BIN/ln" <<'EOF'
#!/usr/bin/env bash
target="${*: -1}"
if [ -n "${STUB_LATE_RACE:-}" ] && [ "${target%"$STUB_LATE_RACE"}" != "$target" ]; then
  echo "late racing edit" > "$target"
fi
exec "$(PATH=$(printf '%s' "$PATH" | sed "s#^$RACE_BIN_DIR:##") command -v ln)" "$@"
EOF
chmod +x "$RACE_BIN/mv" "$RACE_BIN/ln"
export RACE_BIN_DIR="$RACE_BIN"

echo "1. behind origin on other files: modified + new + deleted file published, sync catches up"
sandbox s1 DS-my-strategy
advance_origin current/other.md 'unrelated\n'
printf 'a\nb\nc\nd\nweek report\n' > "$REPO/current/plan.md"
echo "new" > "$REPO/current/new.md"
rm "$REPO/current/gone.md"
reflog_before=$(git -C "$REPO" reflog | count)
index_before=$(git -C "$REPO" ls-files -s | sha1sum)
assert "$(run_guard current/plan.md current/new.md current/gone.md)" 0 "exit code"
assert "$(git -C "$BARE" show main:current/plan.md | tail -1)" "week report" "origin got the modified file"
assert "$(git -C "$BARE" show main:current/new.md)" "new" "origin got the new file"
assert "$(git -C "$BARE" ls-tree main -- current/gone.md | count)" 0 "origin lost the deleted file"
assert "$(git -C "$BARE" show main:current/other.md)" "unrelated" "the other publication survived"
assert "$(git -C "$REPO" reflog | count)" "$reflog_before" "the guard moved no branch in the main checkout"
assert "$(git -C "$REPO" ls-files -s | sha1sum)" "$index_before" "the guard did not stage in the main checkout"
assert "$(git -C "$REPO" worktree list | count)" 1 "the temporary worktree is gone"
assert "$(count < "$IWE/sync.calls")" 0 "the sync is not run inside the guard"
assert "$([ -s "$IWE/.iwe-runtime/canon-sync-requested" ] && echo yes)" yes "the sync was requested"
assert "$(run_sync)" 0 "the next sync pass admits the published files"
assert "$(git -C "$REPO" rev-parse HEAD)" "$(git -C "$BARE" rev-parse main)" "main checkout fast-forwarded to origin"
assert "$(git -C "$REPO" status --porcelain | count)" 0 "main checkout clean after the pass"

echo "2. Fable H1: origin changed the same file meanwhile -> the merged published version is written"
sandbox s2 DS-my-strategy
advance_origin current/plan.md 'a-origin\nb\nc\nd\ne\n'
printf 'a\nb\nc\nd\ne-week\n' > "$REPO/current/plan.md"
assert "$(run_guard current/plan.md)" 0 "exit code"
assert "$(cat "$REPO/current/plan.md")" "$(printf 'a-origin\nb\nc\nd\ne-week')" "the file shows the published merge, not an older version (Fable M3)"
assert "$(run_sync)" 0 "the sync pass is not blocked by the file (was: dirty-overlap)"
assert "$(git -C "$REPO" status --porcelain | count)" 0 "main checkout clean after the pass"
assert "$(ls "$REPO/.git/week-close-handover" 2>/dev/null | count)" 0 "no backup left behind"

echo "3. nothing to commit: exit 1, nothing published"
sandbox s3 DS-my-strategy
assert "$(run_guard current/plan.md)" 1 "exit code"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not called"

echo "4. publication fails: exit 2, main checkout untouched"
sandbox s4 DS-my-strategy
echo "draft" > "$REPO/current/plan.md"
head_before=$(git -C "$REPO" rev-parse HEAD)
assert "$(STUB_PUBLISH_RC=22 run_guard current/plan.md)" 2 "exit code"
assert "$(cat "$REPO/current/plan.md")" "draft" "the edit is still there"
assert "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "HEAD unchanged"
assert "$(git -C "$BARE" show main:current/plan.md | head -1)" "a" "origin unchanged"

echo "5. file edited after publication: kept, reported, exit 0"
sandbox s5 DS-my-strategy
advance_origin current/plan.md 'a-origin\nb\nc\nd\ne\n'
printf 'a\nb\nc\nd\ne-week\n' > "$REPO/current/plan.md"
assert "$(STUB_EDIT_AFTER=current/plan.md run_guard current/plan.md)" 0 "exit code"
assert "$(tail -1 "$REPO/current/plan.md")" "edited after publication" "the later edit is preserved"
assert "$(grep -c 'без замены опубликованной версией' "$T/out")" 1 "the kept file is reported"

echo "6. main checkout ahead of origin: exit 2, nothing published"
sandbox s6 DS-my-strategy
echo local > "$REPO/current/keep.md"
git -C "$REPO" commit -qam "local only"
echo "x" > "$REPO/current/plan.md"
assert "$(run_guard current/plan.md)" 2 "exit code"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not called"

echo "7. not the main checkout: the old commit-and-push loop (run without the wrapper)"
sandbox s7 other-repo
echo "report" > "$REPO/current/plan.md"
assert "$(GUARD_PATH_OVERRIDE="$PATH" run_guard current/plan.md)" 0 "exit code"
assert "$(git -C "$BARE" show main:current/plan.md)" "report" "origin got the file"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not used"

echo "8. a writer recreates the file right after it is moved aside: its edit wins, ours is backed up"
sandbox s8 DS-my-strategy
advance_origin current/plan.md 'a-origin\nb\nc\nd\ne\n'
printf 'a\nb\nc\nd\ne-week\n' > "$REPO/current/plan.md"
assert "$(STUB_RACE=current/plan.md run_guard current/plan.md)" 0 "exit code"
assert "$(cat "$REPO/current/plan.md")" "racing edit" "the racing edit is not overwritten"
assert "$(grep -c 'сохранены в' "$T/out")" 1 "the backup is named"
assert "$(tail -1 "$REPO"/.git/week-close-handover/*/1)" "e-week" "the backup holds the committed bytes"

echo "9. a writer creates the file just before the published version is linked in: the writer wins"
sandbox s9 DS-my-strategy
advance_origin current/plan.md 'a-origin\nb\nc\nd\ne\n'
printf 'a\nb\nc\nd\ne-week\n' > "$REPO/current/plan.md"
assert "$(STUB_LATE_RACE=current/plan.md run_guard current/plan.md)" 0 "exit code"
assert "$(cat "$REPO/current/plan.md")" "late racing edit" "the late edit is not overwritten"
assert "$(grep -c 'без замены опубликованной версией' "$T/out")" 1 "the file is reported as kept"

echo "10. an executable file keeps its mode through publication and hand-over"
sandbox s10 DS-my-strategy
printf '#!/bin/sh\necho 1\necho 2\necho 3\n' > "$REPO/current/run.sh"
chmod +x "$REPO/current/run.sh"
git -C "$REPO" add current/run.sh && git -C "$REPO" commit -qm exec && git -C "$REPO" push -q origin main
other="$T/other-exec"; git clone -q "$BARE" "$other"
printf '#!/bin/sh\necho 1-origin\necho 2\necho 3\n' > "$other/current/run.sh"
git -C "$other" -c user.email=t@t -c user.name=t commit -qam "other exec" && git -C "$other" push -q origin main
printf '#!/bin/sh\necho 1\necho 2\necho 3-week\n' > "$REPO/current/run.sh"
assert "$(run_guard current/run.sh)" 0 "exit code"
assert "$(git -C "$BARE" ls-tree main -- current/run.sh | cut -c1-6)" 100755 "origin kept mode 100755"
assert "$([ -x "$REPO/current/run.sh" ] && echo yes)" yes "the handed-over file is executable"
assert "$(run_sync)" 0 "the sync pass admits it"
assert "$(git -C "$REPO" status --porcelain | count)" 0 "clean after the pass, mode included"

echo "11. a symlink in the list is published and stays in place"
sandbox s11 DS-my-strategy
ln -s keep.md "$REPO/current/link.md"
git -C "$REPO" add current/link.md && git -C "$REPO" commit -qm link && git -C "$REPO" push -q origin main
rm "$REPO/current/link.md" && ln -s plan.md "$REPO/current/link.md"
assert "$(run_guard current/link.md)" 0 "exit code"
assert "$(git -C "$BARE" cat-file -p main:current/link.md)" plan.md "origin got the new link target"
assert "$(readlink "$REPO/current/link.md")" plan.md "the link is still in place"

echo "12. Fable M1: a path that exists nowhere is an error, not a silent drop"
sandbox s12 DS-my-strategy
echo "report" > "$REPO/current/keep.md"
assert "$(run_guard current/keep.md current/typo.md)" 2 "exit code"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not called"
assert "$(git -C "$REPO" worktree list | count)" 1 "no temporary worktree created"

echo "13. Fable M4: the repository's commit hooks run and can refuse"
sandbox s13 DS-my-strategy
printf '#!/bin/sh\necho "hook refused" >&2\nexit 1\n' > "$REPO/.git/hooks/pre-commit"
chmod +x "$REPO/.git/hooks/pre-commit"
echo "report" > "$REPO/current/keep.md"
assert "$(run_guard current/keep.md)" 2 "exit code"
assert "$(grep -c 'hook refused' "$T/out")" 1 "the hook ran"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not called"
assert "$(cat "$REPO/current/keep.md")" "report" "the edit is still there"
assert "$(git -C "$REPO" worktree list | count)" 1 "the temporary worktree is gone"

echo "14. review В1: origin moves the same file again before the sync pass -- still admitted"
sandbox s14 DS-my-strategy
printf 'a\nb\nc\nd\ne-week\n' > "$REPO/current/plan.md"
assert "$(run_guard current/plan.md)" 0 "exit code"
advance_origin current/plan.md 'a-next\nb\nc\nd\ne-week\n'
assert "$(run_sync)" 0 "the superseded published version does not block the sync"
assert "$(head -1 "$REPO/current/plan.md")" "a-next" "the newest version is in place"
assert "$(git -C "$REPO" status --porcelain | count)" 0 "clean after the pass"

echo "15. review С2: a retry after the files were already published finishes the hand-over (exit 1)"
sandbox s15 DS-my-strategy
printf 'a\nb\nc\nd\ne-week\n' > "$REPO/current/plan.md"
advance_origin current/plan.md 'a\nb\nc\nd\ne-week\n'
advance_origin current/plan.md 'a-next\nb\nc\nd\ne-week\n'
assert "$(run_guard current/plan.md)" 1 "exit code: already done on a previous attempt"
assert "$(count < "$IWE/publish.calls")" 0 "nothing published again"
assert "$(head -1 "$REPO/current/plan.md")" "a-next" "the published version is handed over"
assert "$([ -s "$IWE/.iwe-runtime/canon-sync-requested" ] && echo yes)" yes "the sync was requested"
assert "$(run_sync)" 0 "the sync pass admits it"

echo "16. review С1: a file staged in the main checkout is refused before anything is committed"
sandbox s16 DS-my-strategy
echo "report" > "$REPO/current/keep.md"
git -C "$REPO" add current/keep.md
assert "$(run_guard current/keep.md)" 2 "exit code"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not called"

echo "17. review В2: an event journal path is refused before anything is committed"
sandbox s17 DS-my-strategy
mkdir -p "$REPO/machine/ledger" && echo "events: 1" > "$REPO/machine/ledger/day.yaml"
assert "$(run_guard machine/ledger/day.yaml)" 2 "exit code"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not called"

echo "18. review Н4: an absolute path inside the checkout is accepted"
sandbox s18 DS-my-strategy
echo "report" > "$REPO/current/keep.md"
assert "$(run_guard "$REPO/current/keep.md")" 0 "exit code"
assert "$(git -C "$BARE" show main:current/keep.md)" "report" "origin got the file"

echo "18b. an absolute path through a symlinked directory is accepted (macOS /var, any host)"
sandbox s18b DS-my-strategy
echo "report" > "$REPO/current/keep.md"
ln -s "$REPO" "$T/s18b/repo-link"
assert "$(run_guard "$T/s18b/repo-link/current/keep.md")" 0 "exit code"
assert "$(git -C "$BARE" show main:current/keep.md)" "report" "origin got the file"

echo "18c. an absolute path outside the checkout is still refused"
sandbox s18c DS-my-strategy
echo "x" > "$T/s18c/outside.md"
assert "$(run_guard "$T/s18c/outside.md")" 2 "exit code"
assert "$(count < "$IWE/publish.calls")" 0 "ds-publish not called"

echo "19. third review С1: published as a merge but the hand-over could not run -> exit 2, not success"
sandbox s19 DS-my-strategy
advance_origin current/plan.md 'a-origin\nb\nc\nd\ne\n'
printf 'a\nb\nc\nd\ne-week\n' > "$REPO/current/plan.md"
flock -x "$IWE/.claude/state/ds-commit.lock" sleep 40 &
holder=$!
sleep 1
assert "$(run_guard current/plan.md)" 2 "exit code"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
assert "$(git -C "$BARE" show main:current/plan.md | tail -1)" "e-week" "the edit is published"
assert "$(tail -1 "$REPO/current/plan.md")" "e-week" "our bytes are untouched"
assert "$(grep -c 'неопубликованные версии этих файлов' "$T/out")" 1 "the blocked file is named"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAIL(S)"; exit 1; fi
