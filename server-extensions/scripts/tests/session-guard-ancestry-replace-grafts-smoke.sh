#!/bin/bash
# session-guard-ancestry-replace-grafts-smoke.sh -- WP-7 Ф161, peer sessions
# 2026-09-21-04-wp537-wp7-fmt-decisions-followup and 2026-09-21-14-wp7-f161-verify-codex
# (Claude+Codex).
#
# session-guard.sh's publish-proof path trusts `git merge-base --is-ancestor`
# to decide "is this local commit already published on origin". A forged
# commit object -- locally installed via `git replace` or the legacy
# `.git/info/grafts` overlay -- that adds an undelivered commit as an extra
# (merge) parent of origin's real tip fools that check: the undelivered
# commit reads back as already-ancestor, i.e. already published. Neither
# forgery touches origin itself; both are purely local state a prepared
# checkout can carry.
#
# Two layers, both fail-loud:
#   1. static: session-guard.sh carries the exact top-level exports before its
#      first ancestry call, and every python block that scrubs GIT_* restores
#      both protections itself (see ancestry-hardening-lib.sh for what the
#      analyzer replays and what it reports instead). The checks are then run
#      against deliberately broken copies of the script, and each broken copy
#      must trip the SPECIFIC rule it targets, so a check that stopped
#      detecting a defect, or a mutant that no longer parses, turns this test
#      red instead of staying quietly green.
#   2. live: against the real git binary, each forgery fools an unguarded
#      merge-base and the exact two exports neutralize it. This layer proves
#      the git mechanism, not session-guard.sh's own control flow; a test that
#      drives the real publish-proof function end to end is a separate task.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The guard next to this test, not a path under $IWE_ROOT: on a host that keeps an untracked
# `iwe-local-config/` copy of the tree (this Mac), the old default checked that stale copy.
SG="${SESSION_GUARD_SCRIPT:-$HERE/../session-guard.sh}"
[ -f "$SG" ] || { echo "FAIL: $SG not found"; exit 1; }
# shellcheck source=ancestry-hardening-lib.sh
. "$HERE/ancestry-hardening-lib.sh"

FAILURES=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "OK: $desc"
  else
    echo "FAIL: $desc (ожидалось '$expected', получено '$actual')"
    FAILURES=$((FAILURES + 1))
  fi
}

ANCESTRY_RE='merge-base --is-ancestor'
violations_of() {
  hardening_violations "$1" "$ANCESTRY_RE"
  python_scrub_blocks_violations "$1"
}
protection_count() {
  grep -oE 'GIT_NO_REPLACE_OBJECTS="1"|GIT_GRAFT_FILE=os\.devnull' "$1" | wc -l | tr -d ' '
}

# --- Layer 1a: the real script ---
check "session-guard.sh: два верхних экспорта точные и стоят до первой проверки предка" "" \
  "$(hardening_violations "$SG" "$ANCESTRY_RE")"
check "session-guard.sh: каждый python-блок с зачисткой GIT_* сам восстанавливает обе защиты" "" \
  "$(python_scrub_blocks_violations "$SG")"

# --- Layer 1b: each broken copy must trip the rule it targets ---
expect_caught() {  # <description> <mutant script> <regex the violations must match>
  local found verdict=MISSED
  found=$(violations_of "$2")
  if printf '%s' "$found" | grep -Eq "$3"; then verdict=caught; fi
  check "мутант ловится нужным правилом: $1" "caught" "$verdict"
}

sed 's|GIT_GRAFT_FILE=os.devnull + "/iwe-no-grafts",||' "$SG" > "$T/m-no-graft-py.sh"
expect_caught "python-блоки без GIT_GRAFT_FILE" "$T/m-no-graft-py.sh" 'does not finally set GIT_GRAFT_FILE'

sed -e 's|GIT_NO_REPLACE_OBJECTS="1",||' -e 's|GIT_GRAFT_FILE=os.devnull + "/iwe-no-grafts",||' "$SG" > "$T/m-no-protection-py.sh"
expect_caught "python-блоки без обеих защит (сверка двух счётчиков между собой проходила на 0 == 0)" \
  "$T/m-no-protection-py.sh" 'does not finally set GIT_NO_REPLACE_OBJECTS'

grep -vxF "$HARDEN_REPLACE_LINE" "$SG" > "$T/m-no-top-replace.sh"
expect_caught "убран верхний GIT_NO_REPLACE_OBJECTS" "$T/m-no-top-replace.sh" 'missing exactly: export GIT_NO_REPLACE_OBJECTS=1'

grep -vxF "$HARDEN_GRAFT_LINE" "$SG" > "$T/m-no-top-graft.sh"
expect_caught "убран верхний GIT_GRAFT_FILE" "$T/m-no-top-graft.sh" 'missing exactly: export GIT_GRAFT_FILE'

awk -v g="$HARDEN_GRAFT_LINE" -v re="$ANCESTRY_RE" '
  $0 == g { next }
  { print }
  !done && $0 !~ /^[[:space:]]*#/ && $0 ~ re { print g; done = 1 }
' "$SG" > "$T/m-graft-after-call.sh"
expect_caught "верхний GIT_GRAFT_FILE перенесён под первую проверку предка" \
  "$T/m-graft-after-call.sh" 'GIT_GRAFT_FILE export .* is not before the first ancestry call'

sed 's|^export GIT_GRAFT_FILE=.*|export GIT_GRAFT_FILE=.git/info/grafts|' "$SG" > "$T/m-graft-bad-value.sh"
expect_caught "верхний GIT_GRAFT_FILE указывает на реальный файл вместо заглушки" \
  "$T/m-graft-bad-value.sh" 'missing exactly: export GIT_GRAFT_FILE'

SECOND_BLOCK=$(grep -n 'not key\.startswith("GIT_")' "$SG" | sed -n 2p | cut -d: -f1)
FIRST_BLOCK=$(grep -n 'not key\.startswith("GIT_")' "$SG" | sed -n 1p | cut -d: -f1)

# One block loses both protections, another gains a duplicate: the total is
# unchanged, so only a per-block check can see it.
awk -v first="$FIRST_BLOCK" -v second="$SECOND_BLOCK" \
    -v dup="_dup = 'GIT_NO_REPLACE_OBJECTS=\"1\" GIT_GRAFT_FILE=os.devnull'" '
  NR >= second && NR <= second + 8 {
    gsub(/GIT_NO_REPLACE_OBJECTS="1",/, "")
    gsub(/GIT_GRAFT_FILE=os\.devnull \+ "\/iwe-no-grafts",/, "")
  }
  { print }
  NR == first { print dup }
' "$SG" > "$T/m-redistributed.sh"
check "перераспределённый мутант сохраняет общий счёт защит (иначе он не доказывает поблочную проверку)" \
  "$(protection_count "$SG")" "$(protection_count "$T/m-redistributed.sh")"
expect_caught "защиты перераспределены между python-блоками при том же общем счёте" \
  "$T/m-redistributed.sh" 'python block at line [0-9]+ does not finally set'

# A block loses both protections from its env.update call but leaves them in a
# comment right next to it: a lexical window check would count the comment.
awk -v second="$SECOND_BLOCK" '
  NR >= second && NR <= second + 8 {
    gsub(/GIT_NO_REPLACE_OBJECTS="1",/, "")
    gsub(/GIT_GRAFT_FILE=os\.devnull \+ "\/iwe-no-grafts",/, "")
  }
  { print }
  NR == second { print "# GIT_NO_REPLACE_OBJECTS=\"1\" GIT_GRAFT_FILE=os.devnull" }
' "$SG" > "$T/m-comment-decoy.sh"
expect_caught "защиты убраны из env.update, но оставлены в соседнем комментарии" \
  "$T/m-comment-decoy.sh" 'does not finally set GIT_NO_REPLACE_OBJECTS'

# The tokens survive inside the env.update call itself, but only as the text of a
# string literal (a decoy keyword argument), not as real keyword arguments.
awk -v second="$SECOND_BLOCK" \
    -v decoy="GIT_NO_LAZY_FETCH=\"1\", DECOY='GIT_NO_REPLACE_OBJECTS=\"1\" GIT_GRAFT_FILE=os.devnull'," '
  NR >= second && NR <= second + 8 {
    gsub(/GIT_NO_REPLACE_OBJECTS="1",/, "")
    gsub(/GIT_GRAFT_FILE=os\.devnull \+ "\/iwe-no-grafts",/, "")
    gsub(/GIT_NO_LAZY_FETCH="1",/, decoy)
  }
  { print }
' "$SG" > "$T/m-literal-decoy.sh"
expect_caught "защиты остались только текстом строкового литерала внутри env.update" \
  "$T/m-literal-decoy.sh" 'does not finally set GIT_NO_REPLACE_OBJECTS'

awk -v second="$SECOND_BLOCK" '
  NR >= second && NR <= second + 8 { gsub(/GIT_NO_REPLACE_OBJECTS="1"/, "GIT_NO_REPLACE_OBJECTS=\"0\"") }
  { print }
' "$SG" > "$T/m-wrong-value.sh"
expect_caught "GIT_NO_REPLACE_OBJECTS в python-блоке выставлен в 0" \
  "$T/m-wrong-value.sh" 'does not finally set GIT_NO_REPLACE_OBJECTS'

# A correct env.update(...) followed, in the same block, by something that undoes it
# or that the analyzer cannot replay faithfully: each such form is reported.
late_mutation() {  # <name> <python appended after the block's env.update; \n separates lines>
  awk -v second="$SECOND_BLOCK" -v extra="$2" '
    { print }
    NR >= second && NR <= second + 8 && /GIT_TERMINAL_PROMPT="0"\)/ { print extra }
  ' "$SG" > "$T/m-$1.sh"
}
late_mutation late-update 'env.update(GIT_NO_REPLACE_OBJECTS="0")'
expect_caught "после верного env.update защита переопределена вторым env.update" \
  "$T/m-late-update.sh" 'does not finally set GIT_NO_REPLACE_OBJECTS'
late_mutation late-subscript 'env["GIT_GRAFT_FILE"] = os.devnull'
expect_caught "после верного env.update GIT_GRAFT_FILE перезаписан через env[...] =" \
  "$T/m-late-subscript.sh" 'does not finally set GIT_GRAFT_FILE'
late_mutation late-opaque 'env.update(**overrides)'
expect_caught "после верного env.update стоит непроверяемая распаковка **overrides" \
  "$T/m-late-opaque.sh" 'cannot evaluate'
late_mutation late-pop 'env.pop("GIT_NO_REPLACE_OBJECTS", None)'
expect_caught "после верного env.update защита удалена через env.pop" "$T/m-late-pop.sh" 'cannot evaluate'
late_mutation alias 'alias = env\nalias.update(GIT_NO_REPLACE_OBJECTS="0")'
expect_caught "env связан со вторым именем, дальнейшие правки через него не отследить" "$T/m-alias.sh" 'aliased'
late_mutation dead-function 'env.update(GIT_NO_REPLACE_OBJECTS="0")\ndef never_called_restore():\n    env.update(GIT_NO_REPLACE_OBJECTS="1")'
expect_caught "защита «восстановлена» только внутри никогда не вызываемой функции" \
  "$T/m-dead-function.sh" 'conditional or nested'
late_mutation conditional 'if os.getcwd():\n    env.update(GIT_NO_REPLACE_OBJECTS="0")'
expect_caught "переопределение спрятано в ветвление, исполнение которого не гарантировано" \
  "$T/m-conditional.sh" 'conditional or nested'
# Writes are recognised by tree context (Store/Del on env or env[...]), so these other
# ways of writing are seen too: annotated and augmented assignment, walrus, dunder call,
# and handing env to a callee that could mutate it.
late_mutation ann-assign 'env["GIT_NO_REPLACE_OBJECTS"]: str = "0"'
expect_caught "защита перезаписана аннотированным присваиванием env[...]: str = ..." \
  "$T/m-ann-assign.sh" 'does not finally set GIT_NO_REPLACE_OBJECTS'
late_mutation aug-assign 'env["GIT_GRAFT_FILE"] += "x"'
expect_caught "защита изменена составным присваиванием env[...] += ..." "$T/m-aug-assign.sh" 'does not replay'
late_mutation walrus '(env := {})'
expect_caught "env пересоздан оператором :=" "$T/m-walrus.sh" 'rebound or deleted'
late_mutation dunder-setitem 'env.__setitem__("GIT_NO_REPLACE_OBJECTS", "0")'
expect_caught "защита перезаписана прямым вызовом env.__setitem__" "$T/m-dunder-setitem.sh" 'cannot evaluate'
late_mutation hand-off 'apply_overrides(env)'
expect_caught "env передан чужой функции, которая может его изменить" "$T/m-hand-off.sh" 'may mutate it'

# A block that copies os.environ under a different variable name is invisible to the
# scrub idiom the analyzer looks for; it must be reported, not silently unchecked.
awk '!done && /not key\.startswith\("GIT_"\)/ { sub(/not key\.startswith\("GIT_"\)/, "not name.startswith(\"GIT_\")"); done = 1 } { print }' \
  "$SG" > "$T/m-renamed-scrub.sh"
expect_caught "блок с зачисткой GIT_* под другим именем переменной не остаётся непроверенным" \
  "$T/m-renamed-scrub.sh" 'copies os.environ.items\(\) without the recognised'

# --- Layer 2: live proof against the real git binary ---
# --template= keeps the test independent of the host's init.templateDir, which
# may lack .git/info/ or carry hooks that would fire on this test's commits.
REPO="$T/repo"
git init -q --template= "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo base > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)
echo real_parent >> "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm real_parent
REAL_PARENT=$(git -C "$REPO" rev-parse HEAD)
echo real_child >> "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm real_child
REAL_CHILD=$(git -C "$REPO" rev-parse HEAD)   # plays origin/main's real tip
git -C "$REPO" checkout -q "$BASE"
echo fake >> "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm fake_undelivered
FAKE=$(git -C "$REPO" rev-parse HEAD)         # plays a session's own undelivered HEAD
git -C "$REPO" checkout -q "$REAL_CHILD"

FORGED_CHILD=$(git -C "$REPO" commit-tree "${REAL_CHILD}^{tree}" -p "$REAL_PARENT" -p "$FAKE" -m "forged merge")

# Scenario 1: refs/replace forgery.
git -C "$REPO" replace "$REAL_CHILD" "$FORGED_CHILD"
git -C "$REPO" merge-base --is-ancestor "$FAKE" "$REAL_CHILD" 2>/dev/null
UNGUARDED_REPLACE=$?
check "refs/replace forgery fools an unguarded merge-base (подтверждает уязвимость)" "0" "$UNGUARDED_REPLACE"
GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null/iwe-no-grafts \
   git -C "$REPO" merge-base --is-ancestor "$FAKE" "$REAL_CHILD" 2>/dev/null
GUARDED_REPLACE=$?
check "хардненинг session-guard.sh нейтрализует подделку через refs/replace" "1" "$GUARDED_REPLACE"
git -C "$REPO" replace -d "$REAL_CHILD"

# Scenario 2: legacy info/grafts forgery. The guarded check below is only
# meaningful when the forgery is installed AND fools the unguarded call;
# otherwise it passes vacuously, so it runs only after both preconditions hold.
mkdir -p "$REPO/.git/info"
echo "$REAL_CHILD $REAL_PARENT $FAKE" > "$REPO/.git/info/grafts"
GRAFTS_INSTALLED=$([ -s "$REPO/.git/info/grafts" ] && echo yes || echo no)
check "подделка info/grafts установлена (предусловие отрицательного контроля)" "yes" "$GRAFTS_INSTALLED"
if [ "$GRAFTS_INSTALLED" = yes ]; then
  git -C "$REPO" merge-base --is-ancestor "$FAKE" "$REAL_CHILD" 2>/dev/null
  UNGUARDED_GRAFTS=$?
  if [ "$UNGUARDED_GRAFTS" -ne 0 ]; then
    # git deprecated info/grafts and will drop it: once it ignores the file the
    # vector is closed upstream and the whole graft section is vacuous.
    echo "SKIP: $(git --version) does not honour info/grafts -- forgery vector closed upstream, graft section skipped"
  else
    GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null/iwe-no-grafts \
       git -C "$REPO" merge-base --is-ancestor "$FAKE" "$REAL_CHILD" 2>/dev/null
    GUARDED_GRAFTS=$?
    check "хардненинг session-guard.sh нейтрализует подделку через info/grafts (подделка обманывала вызов без защиты)" "1" "$GUARDED_GRAFTS"
  fi
fi
rm -f "$REPO/.git/info/grafts"

# Sanity: a genuinely delivered commit must still pass with the hardening on
# (the fix must not turn into a blanket "always reject").
GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null/iwe-no-grafts \
   git -C "$REPO" merge-base --is-ancestor "$REAL_PARENT" "$REAL_CHILD" 2>/dev/null
HONEST_CHECK=$?
check "хардненинг не ломает честную (не подделанную) проверку предка" "0" "$HONEST_CHECK"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "=== $FAILURES ПРОВЕРОК FAILED ==="
  exit 1
fi
