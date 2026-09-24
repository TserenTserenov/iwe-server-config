#!/usr/bin/env bash
# week-close-commit-guard-forgery-smoke.sh -- WP-7 Ф161, peer session
# 2026-09-21-14-wp7-f161-verify-codex (Claude+Codex).
#
# week-close-commit-guard.sh decides "nothing to commit" when the staged diff is
# empty AND `git merge-base --is-ancestor HEAD origin/<branch>` says HEAD is
# already on origin. A local forgery (`git replace` or the legacy
# `.git/info/grafts`) that makes a not-yet-pushed commit look like an ancestor of
# origin's tip turns that into a silent non-delivery: the script exits 1
# "nothing to commit" and the commit never reaches origin.
#
# The forgery is installed by a git wrapper right AFTER the script's own
# `git pull --rebase`: a forgery present before the pull could change how the
# pull itself behaves and blur what is being tested. Each scenario asserts the
# observable outcome on the bare origin (what was actually delivered), and the
# forgery must be both installed and effective against an unguarded call before
# the hardened outcome is trusted -- otherwise the test would pass vacuously.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-$HERE/../week-close-commit-guard.sh}"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }
# shellcheck source=ancestry-hardening-lib.sh
. "$HERE/ancestry-hardening-lib.sh"

REAL_GIT=$(command -v git)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
assert() {
  if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails + 1)); fi
}

echo "static: exact exports before the first ancestry call"
assert "$(hardening_violations "$SCRIPT" 'merge-base --is-ancestor')" "" "week-close-commit-guard.sh is hardened"

mkdir -p "$T/bin"
cat > "$T/bin/git" <<'WRAPPER'
#!/usr/bin/env bash
# Delegates to the real git; right after the first successful `git pull` it
# installs the forgery selected by FORGE_KIND (replace | grafts | none).
"$REAL_GIT" "$@"
rc=$?
if [ "${1:-}" = pull ] && [ "$rc" -eq 0 ] && [ ! -e "$FORGE_MARK" ]; then
  : > "$FORGE_MARK"
  case "$FORGE_KIND" in
    replace)
      env -u GIT_NO_REPLACE_OBJECTS -u GIT_GRAFT_FILE "$REAL_GIT" replace "$FORGE_ORIGIN_TIP" "$FORGE_OBJECT" ;;
    grafts)
      mkdir -p "$("$REAL_GIT" rev-parse --git-dir)/info"
      echo "$FORGE_ORIGIN_TIP $FORGE_LOCAL_COMMIT" >> "$("$REAL_GIT" rev-parse --git-dir)/info/grafts" ;;
  esac
  # Effectiveness probe taken NOW, before the script under test can push: once
  # it has pushed, HEAD is honestly an ancestor of origin/main with no forgery.
  if [ "$FORGE_KIND" != none ]; then
    env -u GIT_NO_REPLACE_OBJECTS -u GIT_GRAFT_FILE "$REAL_GIT" merge-base --is-ancestor "$FORGE_LOCAL_COMMIT" origin/main 2>/dev/null
    echo $? > "$FORGE_MARK.fooled"
  fi
fi
exit $rc
WRAPPER
chmod +x "$T/bin/git"

run_scenario() {  # <replace|grafts|none>
  local kind="$1" origin work base local_commit forged out rc installed fooled
  origin="$T/$kind-origin.git"; work="$T/$kind-work"
  "$REAL_GIT" init -q --bare --template= "$origin"
  "$REAL_GIT" init -q --template= -b main "$work"
  w() { "$REAL_GIT" -C "$work" -c user.name=t -c user.email=t@t "$@"; }
  echo base > "$work/a.txt"; w add a.txt; w commit -qm base
  w remote add origin "$origin"; w push -q origin main
  base=$(w rev-parse HEAD)
  echo mine > "$work/f.txt"; w add f.txt; w commit -qm "previous attempt: committed, not pushed"
  local_commit=$(w rev-parse HEAD)
  # An object with origin's tree whose parent is the undelivered commit.
  forged=$(w commit-tree "${base}^{tree}" -p "$local_commit" -m forged)

  out=$(PATH="$T/bin:$PATH" REAL_GIT="$REAL_GIT" FORGE_KIND="$kind" FORGE_MARK="$T/$kind.mark" \
        FORGE_ORIGIN_TIP="$base" FORGE_LOCAL_COMMIT="$local_commit" FORGE_OBJECT="$forged" \
        bash "$SCRIPT" "$work" "test commit message" f.txt 2>&1)
  rc=$?

  if [ "$kind" = none ]; then
    assert "$rc" "0" "no forgery: exit 0 (pushed)"
    assert "$("$REAL_GIT" -C "$origin" rev-parse refs/heads/main)" "$local_commit" "no forgery: origin received the commit"
    return
  fi

  case "$kind" in
    replace) installed=$([ "$(w for-each-ref refs/replace | wc -l | tr -d ' ')" = 1 ] && echo yes || echo no) ;;
    grafts)  installed=$([ -s "$work/.git/info/grafts" ] && echo yes || echo no) ;;
  esac
  assert "$installed" "yes" "$kind: forgery was installed after the pull (precondition)"
  [ "$installed" = yes ] || return
  fooled=$(cat "$T/$kind.mark.fooled" 2>/dev/null || echo missing)
  assert "$([ "$fooled" = missing ] && echo no || echo yes)" "yes" "$kind: effectiveness probe was recorded inside the wrapper, before the script could push (precondition)"
  [ "$fooled" != missing ] || return
  if [ "$fooled" -ne 0 ]; then
    # Only the deprecated grafts vector may disappear from git; refs/replace is
    # supported, so a replace forgery that fools nothing means the test is broken.
    if [ "$kind" = grafts ]; then
      echo "  SKIP $kind: $("$REAL_GIT" --version) ignores this forgery -- vector closed upstream, scenario skipped"
    else
      assert "$fooled" "0" "$kind: the forgery fools an unguarded merge-base (precondition; refs/replace is still supported)"
    fi
    return
  fi
  assert "$rc" "0" "$kind: exit 0, the commit is pushed instead of 'nothing to commit'"
  assert "$("$REAL_GIT" -C "$origin" rev-parse refs/heads/main)" "$local_commit" "$kind: origin received the undelivered commit"
  assert "$(printf '%s' "$out" | grep -c 'нечего коммитить')" "0" "$kind: the 'nothing to commit' verdict was not reached"
}

for kind in none replace grafts; do
  echo "scenario: $kind"
  run_scenario "$kind"
done

[ "$fails" = 0 ] && echo "PASS: all scenarios" || { echo "FAIL: $fails assertion(s)"; exit 1; }
