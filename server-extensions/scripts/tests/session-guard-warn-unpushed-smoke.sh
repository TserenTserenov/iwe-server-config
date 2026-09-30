#!/usr/bin/env bash
# session-guard-warn-unpushed-smoke.sh -- WP-561 Ч2.
#
# close's "unpushed commits" warning used to count HEAD...origin/main over the
# whole checkout, so another agent's local commits in a shared checkout made
# every close warn about work that is not this session's. The warning must now
# cover only commits this session claimed (note-commit claims and the PREPARED
# source set); the rest of the local-only commits is an info line.
#
# The helpers live inside close() as nested functions, so they are extracted
# from the shipped session-guard.sh (not copied) and driven against a sandbox
# repo + a hand-built semaphore. Nothing here touches ~/IWE or real semaphores.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-warn-unpushed.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE="$TEST_ROOT/fixture.sh"
: > "$FIXTURE"
extract_fn() {  # <indent> <function-name> -- top-level (indent "") or nested ("  ")
  awk -v ind="$1" -v fn="$2" '
    index($0, ind fn "() {") == 1 { active = 1 }
    active {
      print
      if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
      if (inpy && $0 == "PY") { inpy = 0; next }
      if (!inpy && $0 == ind "}") { active = 0; exit }
    }
  ' "$GUARD"
}
extract_fn "" _unique_record_field >> "$FIXTURE"
for fn in _session_claimed_commits _session_commit_is_delivered _warn_unpushed; do
  extract_fn "  " "$fn" >> "$FIXTURE"
  grep -q "^  ${fn}() {" "$FIXTURE" || { echo "FAIL: fixture setup -- ${fn}() not found in session-guard.sh" >&2; exit 1; }
done
# shellcheck source=/dev/null
source "$FIXTURE"

fail_test() { echo "FAIL: $1" >&2; exit 1; }

ORIGIN="$TEST_ROOT/origin.git"
REPO="$TEST_ROOT/repo"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" remote add origin "$ORIGIN"
commit() {  # <file> -> prints the new HEAD
  echo "$1 $RANDOM" > "$REPO/$1"
  git -C "$REPO" add "$1"
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}
commit base >/dev/null
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

_sem_read="$TEST_ROOT/sem.closed"
warn_output() { { _warn_unpushed "$REPO" >/dev/null; } 2>&1; }

# --- T1: a foreign local commit only -> no warning about this session, info line.
printf 'wp: WP-561\n' > "$_sem_read"
commit foreign >/dev/null
OUT=$(warn_output)
case "$OUT" in *"коммита этой сессии"*) fail_test "T1: warned about a foreign local commit as if it were ours: $OUT" ;; esac
case "$OUT" in *"ещё 1 чужих локальных коммитов"*) ;; *) fail_test "T1: info line about foreign commits missing: $OUT" ;; esac
echo "PASS: T1 -- foreign local commit gives an info line, not a warning"

# --- T2: our own undelivered claimed commit -> warning, foreign count excludes it.
OWN=$(commit own)
printf 'wp: WP-561\ncommit: repo %s\n' "$OWN" > "$_sem_read"
OUT=$(warn_output)
case "$OUT" in *"1 незапушенных коммита этой сессии"*) ;; *) fail_test "T2: no warning about our own unpushed commit: $OUT" ;; esac
case "$OUT" in *"ещё 1 чужих локальных коммитов"*) ;; *) fail_test "T2: foreign count should stay 1 (own commit excluded): $OUT" ;; esac
echo "PASS: T2 -- own unpushed commit warns; foreign count excludes it"

# --- T3: own commit delivered by cherry-pick (different OID upstream) -> no warning.
git -C "$REPO" clone -q "$ORIGIN" "$TEST_ROOT/other"
git -C "$TEST_ROOT/other" config user.email test@example.com
git -C "$TEST_ROOT/other" config user.name Test
git -C "$TEST_ROOT/other" fetch -q "$REPO" main
git -C "$TEST_ROOT/other" cherry-pick "$OWN" >/dev/null
git -C "$TEST_ROOT/other" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
OUT=$(warn_output)
case "$OUT" in *"коммита этой сессии"*) fail_test "T3: patch-equivalent own commit still warned: $OUT" ;; esac
echo "PASS: T3 -- patch-equivalent (cherry-picked) own commit is delivered"

# --- T4: the PREPARED source set counts as claimed too.
SRC=$(git -C "$REPO" rev-list -n1 --grep=foreign HEAD)
printf 'wp: WP-561\nclose_delivery_source_commits: ["%s"]\n' "$SRC" > "$_sem_read"
OUT=$(warn_output)
case "$OUT" in *"1 незапушенных коммита этой сессии"*) ;; *) fail_test "T4: close_delivery_source_commits not treated as ours: $OUT" ;; esac
echo "PASS: T4 -- close_delivery_source_commits are this session's commits"

# --- WP-561 Ч2b: two cold-review findings. Each scenario runs in a subshell
# against a fixture file, so the same scenario can be replayed against a mutant
# of the shipped functions and must then fail.
new_sandbox_repo() {  # <name> -> sets ORIGIN and REPO; base commit pushed
  ORIGIN="$TEST_ROOT/$1-origin.git"
  REPO="$TEST_ROOT/$1-repo"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" remote add origin "$ORIGIN"
  commit base >/dev/null
  git -C "$REPO" push -q origin main
  git -C "$REPO" fetch -q origin
}

add_foreign_commits() {  # <count>: empty local commits on top of HEAD, via fast-import
  python3 - "$1" "$(git -C "$REPO" rev-parse HEAD)" <<'PYEOF' | git -C "$REPO" fast-import --quiet
import sys

count, head = int(sys.argv[1]), sys.argv[2]
out = sys.stdout.buffer
for i in range(count):
    message = b"foreign %d" % i
    out.write(b"commit refs/heads/main\n")
    out.write(b"committer Test <test@example.com> %d +0000\n" % (1790000000 + i))
    out.write(b"data %d\n%s\n" % (len(message), message))
    if i == 0:
        out.write(b"from " + head.encode() + b"\n")
    out.write(b"\n")
PYEOF
}

# Finding 2: `printf list | grep -qx oid` under pipefail loses the match when
# grep exits early and printf is SIGPIPEd; it needs a list beyond the pipe
# buffer (64 KiB on macOS: 2500 OIDs are 102 KB), the own commit sits on top.
scenario_large_foreign_list() {  # <fixture>
  # shellcheck source=/dev/null
  source "$1"
  new_sandbox_repo large
  local foreign=2500 own out
  add_foreign_commits "$foreign"
  own=$(commit own)
  printf 'wp: WP-561\ncommit: repo %s\n' "$own" > "$_sem_read"
  out=$(warn_output)
  case "$out" in *"ещё $foreign чужих локальных коммитов"*) ;; *) fail_test "large list: foreign count must be exactly $foreign: $out" ;; esac
  case "$out" in *"1 незапушенных коммита этой сессии"*) ;; *) fail_test "large list: own commit warning missing: $out" ;; esac
}

# Finding 1: `git cherry` had no timeout. The shims make the per-commit probe
# hang and shorten the production 30 s cap to 1 s; the own commit is delivered
# upstream by cherry-pick, so only the failed probe can make it look undelivered.
REAL_GIT=$(command -v git)
REAL_TIMEOUT=$(command -v timeout)
mkdir -p "$TEST_ROOT/shims"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" cherry origin/main "*) exec sleep 8 ;;\nesac\nexec "%s" "$@"\n' \
  "$REAL_GIT" > "$TEST_ROOT/shims/git"
printf '#!/usr/bin/env bash\nshift\nexec "%s" 1 "$@"\n' "$REAL_TIMEOUT" > "$TEST_ROOT/shims/timeout"
chmod +x "$TEST_ROOT/shims/git" "$TEST_ROOT/shims/timeout"

scenario_hanging_cherry() {  # <fixture>
  # shellcheck source=/dev/null
  source "$1"
  new_sandbox_repo hang
  local own out started elapsed
  # An old committer date keeps the cherry-picked copy a different object: with
  # the same parent and second it would be this very commit, already upstream.
  own=$(GIT_COMMITTER_DATE="2026-09-01T10:00:00+00:00" commit own)
  git clone -q "$ORIGIN" "$TEST_ROOT/hang-other"
  git -C "$TEST_ROOT/hang-other" config user.email test@example.com
  git -C "$TEST_ROOT/hang-other" config user.name Test
  git -C "$TEST_ROOT/hang-other" fetch -q "$REPO" main
  git -C "$TEST_ROOT/hang-other" cherry-pick "$own" >/dev/null
  git -C "$TEST_ROOT/hang-other" push -q origin HEAD:main
  git -C "$REPO" fetch -q origin
  printf 'wp: WP-561\ncommit: repo %s\n' "$own" > "$_sem_read"
  export PATH="$TEST_ROOT/shims:$PATH"
  started=$SECONDS
  out=$(warn_output)
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 6 ] || fail_test "hanging cherry: the warning step took ${elapsed}s, the cap did not fire"
  case "$out" in *"не уложился в 30 с: коммит $own"*) ;; *) fail_test "hanging cherry: no unverified-commit line: $out" ;; esac
  case "$out" in *"1 незапушенных коммита этой сессии"*) ;; *) fail_test "hanging cherry: unverified commit not reported as undelivered: $out" ;; esac
}

make_mutant_fixture() {  # <name> <original text> <replacement text> -> prints fixture path
  local path="$TEST_ROOT/mutant-$1.sh"
  python3 - "$FIXTURE" "$path" "$2" "$3" <<'PYEOF' || fail_test "cannot build mutant $1"
import sys

source, target, old, new = sys.argv[1:]
text = open(source, encoding="utf-8").read()
if text.count(old) != 1:
    raise SystemExit("mutation anchor not found exactly once: " + old)
open(target, "w", encoding="utf-8").write(text.replace(old, new))
PYEOF
  printf '%s\n' "$path"
}

expect_scenario_fails() {  # <label> <scenario> <mutant fixture>
  local out
  if out=$( ( "$2" "$3" ) 2>&1 ); then
    fail_test "$1: the mutant passed the scenario, so the scenario proves nothing"
  fi
  echo "    caught by: $(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-160)"
}

( scenario_large_foreign_list "$FIXTURE" ) || fail_test "T5: large foreign list scenario failed on the shipped code"
echo "PASS: T5 -- 2500 foreign local commits: the foreign count is exact, own commit on top"
MUT_PIPELINE=$(make_mutant_fixture pipeline \
  "      case \$'\\n'\"\$local_only\"\$'\\n' in
        *\$'\\n'\"\$oid\"\$'\\n'*) own_in_ahead=\$((own_in_ahead + 1)) ;;
      esac" \
  "      printf '%s\\n' \"\$local_only\" | grep -qx \"\$oid\" && own_in_ahead=\$((own_in_ahead + 1))")
expect_scenario_fails "T5 mutant (old grep pipeline)" scenario_large_foreign_list "$MUT_PIPELINE"
echo "PASS: T5 mutant -- the old printf|grep pipeline miscounts on the same list"

( scenario_hanging_cherry "$FIXTURE" ) || fail_test "T6: hanging cherry scenario failed on the shipped code"
echo "PASS: T6 -- a hanging git cherry is capped; the commit is reported as unverified and undelivered"
MUT_NO_CAP=$(make_mutant_fixture no-cap 'cherry_out=$(timeout 30 git ' 'cherry_out=$(git ')
expect_scenario_fails "T6 mutant (no timeout)" scenario_hanging_cherry "$MUT_NO_CAP"
MUT_TIMEOUT_DELIVERED=$(make_mutant_fixture timeout-delivered \
  '      return 1
    fi
    case "$cherry_out" in' \
  '      return 0
    fi
    case "$cherry_out" in')
expect_scenario_fails "T6 mutant (timeout read as delivered)" scenario_hanging_cherry "$MUT_TIMEOUT_DELIVERED"
echo "PASS: T6 mutants -- no cap, or a timeout read as delivered, fail the scenario"

echo "ALL PASS: session-guard-warn-unpushed-smoke.sh"
