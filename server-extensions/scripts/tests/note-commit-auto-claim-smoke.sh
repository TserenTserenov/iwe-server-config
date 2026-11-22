#!/usr/bin/env bash
# Regression for WP-484 I-34 (4) / WP-561 Ф82: `note-commit <sha> --auto-claim`.
#
# 21.11 a quick close was refused three times with no-owned-commit-evidence for
# commits the agent had made in its own isolated copy and forgot to declare with
# note-commit. The guard now claims such a commit itself, but only when the commit
# is in the chain from the base recorded at open to the tip of the session's
# registered isolated branch, is not a merge, touches only paths the session
# claimed (note-file) or its own report, was created in the copy itself (its HEAD
# reflog, not a fast-forward/reset/rebase onto a neighbour's branch; A12-A16), and
# no unknown commit precedes it. Every
# other case keeps the refusal and names the failed condition, writing nothing.
#
# The session is opened by the real `open --isolate` (which must record
# isolated_base); paths are claimed by the real `note-file`. All artifacts live in
# mktemp; nothing real is touched. Handler-side scenarios (commit-push.sh asking for
# the auto-claim before refusing) live in DS-my-strategy:
# scripts/tests/commit-push-auto-claim-smoke.sh.
#
# Usage: bash scripts/tests/note-commit-auto-claim-smoke.sh  (exit 0 = all green)
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
[ -f "$GUARD" ] || { echo "не найден проверяемый скрипт: $GUARD"; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/note-commit-auto-claim.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- ожидали «$2», получили «$3»"; fi
}

cfg() { git -C "$1" config user.email test@example.com; git -C "$1" config user.name test; git -C "$1" config commit.gpgsign false; }
mkcommit() {  # mkcommit <repo> <subject> <path> <content> [<path> <content>...] -> sha
  local repo="$1" msg="$2"
  shift 2
  while [ $# -ge 2 ]; do
    mkdir -p "$(dirname "$repo/$1")"
    printf '%s\n' "$2" > "$repo/$1"
    git -C "$repo" add -- "$1"
    shift 2
  done
  git -C "$repo" commit -qm "$msg"
  git -C "$repo" rev-parse HEAD
}

REPO_NAME="DS-strategy"
REPO="$TEST_ROOT/$REPO_NAME"
ORIGIN="$TEST_ROOT/origin.git"
git init --bare -q -b main "$ORIGIN"
git init -q -b main "$REPO"
cfg "$REPO"
git -C "$REPO" remote add origin "$ORIGIN"
mkdir -p "$REPO/inbox/WP-484" "$REPO/current" "$REPO/notes"
printf '%s\n' 'hypothesis_relation: "tests"' > "$REPO/inbox/WP-484/WP-484.md"
printf 'seed\n' > "$REPO/current/claimed.md"
printf 'seed\n' > "$REPO/current/other.md"
git -C "$REPO" add inbox current
git -C "$REPO" commit -qm init
git -C "$REPO" push -q -u origin main

MC="$TEST_ROOT/MC-sessions"
git init -q -b main "$MC"
cfg "$MC"
printf 'sessions\n' > "$MC/README.md"
git -C "$MC" add README.md
git -C "$MC" commit -qm init

export IWE_ROOT="$TEST_ROOT"
export IWE_SESSIONS_ROOT="$MC"
export CLAUDE_CODE_SESSION_ID="aaaaaaaa-1111-2222-3333-444444444444"
export IWE_GOVERNANCE_REPO="$REPO_NAME"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

# open_session <slug>: real `open --isolate`; sets SEM SID WT BR
open_session() {
  (cd "$REPO" && bash "$GUARD" open --wp WP-484 --task fixture --slug "$1" --agent fixture --isolate --close-path quick-close) \
    >"$TEST_ROOT/open-$1.out" 2>&1 || { cat "$TEST_ROOT/open-$1.out"; echo "open --isolate failed"; exit 1; }
  SEM=$(grep -l "^slug: $1\$" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
  SID=$(sed -n 's/^session_id: //p' "$SEM")
  WT=$(sed -n 's/^isolated_worktree: //p' "$SEM")
  BR=$(sed -n 's/^isolated_branch: //p' "$SEM")
  cfg "$WT"
}
note_file() {  # note_file <path>; a path ending in "/" is created as a directory first (a directory claim)
  case "$1" in */) mkdir -p "$WT/$1" ;; esac
  (cd "$WT" && bash "$GUARD" note-file "$1" --agent fixture --session-id "$SID") >/dev/null 2>&1
}
auto() {  # auto <sha> -> OUT RC
  OUT=$(cd "$REPO" && bash "$GUARD" note-commit "$1" --auto-claim --repo "$REPO_NAME" --agent fixture --session-id "$SID" 2>&1)
  RC=$?
}
claims_of() { grep -c "^commit: $REPO_NAME $1 " "$SEM" | tr -d ' '; }

echo "== open --isolate записывает базу копии =="
open_session own
BASE=$(git -C "$REPO" rev-parse origin/main)
check "A0 isolated_base = вершина origin/main в момент open" "$BASE" "$(sed -n 's/^isolated_base: //p' "$SEM")"
check "A0.1 охранник объявляет возможность note-commit-auto-claim" "yes" \
  "$(bash "$GUARD" capabilities | grep -qx note-commit-auto-claim && echo yes || echo no)"
note_file current/claimed.md
note_file notes/

echo "== свой незаявленный коммит цепочки, только заявленные пути =="
C1=$(mkcommit "$WT" "own: claimed file" current/claimed.md v1)
auto "$C1"
check "A1 заявлен автоматически" "0|AUTO-CLAIMED $C1" "$RC|$(printf '%s\n' "$OUT" | grep -E '^AUTO-CLAIMED ')"
check "A1.1 обычная 4-полевая заявка: копия и ветка сессии" "1" "$(grep -cx "commit: $REPO_NAME $C1 $WT $BR" "$SEM" | tr -d ' ')"
check "A1.2 рядом пометка автоматической заявки" "own-isolated-chain|$BASE" \
  "$(grep '^commit_auto: ' "$SEM" | sed 's/^commit_auto: //' | jq -r --arg s "$C1" 'select(.sha == $s) | .rule + "|" + .base')"

echo "== уже заявленный коммит: без изменений =="
SNAP=$(cat "$SEM")
auto "$C1"
check "A2 ALREADY-CLAIMED, семафор побайтно тот же" "0|ALREADY-CLAIMED $C1|same" \
  "$RC|$(printf '%s\n' "$OUT" | grep -E '^ALREADY-CLAIMED ')|$([ "$SNAP" = "$(cat "$SEM")" ] && echo same || echo changed)"

echo "== незаявленный путь =="
C2=$(mkcommit "$WT" "own: claimed + unclaimed" current/claimed.md v2 current/other.md touched)
SNAP=$(cat "$SEM")
auto "$C2"
check "A3 отказ unclaimed-path называет путь, ничего не записано" "1|yes|0|same" \
  "$RC|$(printf '%s\n' "$OUT" | grep -q '^AUTO-CLAIM-REFUSED unclaimed-path: .*current/other.md' && echo yes || echo no)|$(claims_of "$C2")|$([ "$SNAP" = "$(cat "$SEM")" ] && echo same || echo changed)"

echo "== неизвестный коммит перед заявляемым =="
C3=$(mkcommit "$WT" "own: after the bad one" notes/a.md note)
auto "$C3"
check "A4 отказ unknown-commit-before (перед ним C2 с незаявленным путём)" "1|yes|0" \
  "$RC|$(printf '%s\n' "$OUT" | grep -q '^AUTO-CLAIM-REFUSED unknown-commit-before: .*current/other.md' && echo yes || echo no)|$(claims_of "$C3")"

echo "== цепочка из двух годных: заявляются обе за один шаг; каталог-заявка покрывает файл внутри =="
open_session chain
note_file current/claimed.md
note_file notes/
D1=$(mkcommit "$WT" "own: first" current/claimed.md c1)
D2=$(mkcommit "$WT" "own: second" notes/deep/b.md c2)
auto "$D2"
check "A5 обе заявлены, D1 раньше D2" "0|AUTO-CLAIMED $D1,AUTO-CLAIMED $D2|1|1" \
  "$RC|$(printf '%s\n' "$OUT" | grep -E '^AUTO-CLAIMED ' | paste -sd, -)|$(claims_of "$D1")|$(claims_of "$D2")"

echo "== слияние =="
git -C "$REPO" checkout -q -b side main
mkcommit "$REPO" "side work" current/other.md side >/dev/null
git -C "$REPO" checkout -q main
mkcommit "$WT" "own: before merge" current/claimed.md c3 >/dev/null
git -C "$WT" merge -q --no-ff -m "merge side" side >/dev/null 2>&1 || { echo "fixture merge failed"; exit 1; }
M=$(git -C "$WT" rev-parse HEAD)
auto "$M"
check "A6 отказ merge-commit" "1|yes|0" \
  "$RC|$(printf '%s\n' "$OUT" | grep -q '^AUTO-CLAIM-REFUSED merge-commit: ' && echo yes || echo no)|$(claims_of "$M")"

echo "== чужой коммит вне цепочки копии =="
git -C "$REPO" checkout -q main
F=$(mkcommit "$REPO" "foreign: neighbour" current/claimed.md foreign)
auto "$F"
check "A7 отказ not-in-session-chain" "1|yes|0" \
  "$RC|$(printf '%s\n' "$OUT" | grep -q '^AUTO-CLAIM-REFUSED not-in-session-chain: ' && echo yes || echo no)|$(claims_of "$F")"
auto "$BASE"
check "A7.1 сама база -- не коммит сессии" "1|yes" \
  "$RC|$(printf '%s\n' "$OUT" | grep -q '^AUTO-CLAIM-REFUSED not-in-session-chain: ' && echo yes || echo no)"

echo "== отчёт сессии (orz_file) разрешён без note-file =="
open_session orz
ORZ_REL=$(sed -n 's/^orz_file: //p' "$SEM")
# The fixture keeps reports inside the same repository so one isolated copy can hold
# both the claimed path and the report: point orz_sessions_dir at a folder of the copy.
mkdir -p "$WT/sessions"
grep -v '^orz_sessions_dir: ' "$SEM" > "$SEM.tmp"; printf 'orz_sessions_dir: %s\n' "$WT/sessions" >> "$SEM.tmp"; mv "$SEM.tmp" "$SEM"
chmod 600 "$SEM"
O1=$(mkcommit "$WT" "own: report" "sessions/$ORZ_REL" report)
auto "$O1"
check "A8 отчёт сессии заявлен автоматически" "0|AUTO-CLAIMED $O1" "$RC|$(printf '%s\n' "$OUT" | grep -E '^AUTO-CLAIMED ')"

echo "== база из журнала ссылок, если isolated_base нет; без журнала -- отказ =="
open_session reflog
note_file current/claimed.md
grep -v '^isolated_base: ' "$SEM" > "$SEM.tmp"; mv "$SEM.tmp" "$SEM"; chmod 600 "$SEM"
R1=$(mkcommit "$WT" "own: reflog base" current/claimed.md r1)
auto "$R1"
check "A9 заявлен, база из журнала ссылок" "0|AUTO-CLAIMED $R1|reflog" \
  "$RC|$(printf '%s\n' "$OUT" | grep -E '^AUTO-CLAIMED ')|$(grep '^commit_auto: ' "$SEM" | sed 's/^commit_auto: //' | jq -r --arg s "$R1" 'select(.sha == $s) | .base_source')"
R2=$(mkcommit "$WT" "own: no base" current/claimed.md r2)
rm -f "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/logs/refs/heads/$BR"
auto "$R2"
check "A9.1 без isolated_base и журнала -- отказ no-recorded-base" "1|yes|0" \
  "$RC|$(printf '%s\n' "$OUT" | grep -q '^AUTO-CLAIM-REFUSED no-recorded-base: ' && echo yes || echo no)|$(claims_of "$R2")"

echo "== семафор без изолированной копии =="
open_session nocopy
grep -v '^isolated_worktree: \|^isolated_branch: ' "$SEM" > "$SEM.tmp"; mv "$SEM.tmp" "$SEM"; chmod 600 "$SEM"
N1=$(mkcommit "$WT" "own: in an unregistered copy" current/claimed.md n1)
auto "$N1"
check "A10 отказ no-isolated-copy" "1|yes" \
  "$RC|$(printf '%s\n' "$OUT" | grep -q '^AUTO-CLAIM-REFUSED no-isolated-copy: ' && echo yes || echo no)"

# neighbour_branch <name> <path> <content> -> sha: a neighbour's unpublished commit
# on its own branch of the shared repository, forked from the copy's base.
neighbour_branch() {
  git -C "$REPO" checkout -q -b "$1" "$BASE_NOW"
  mkcommit "$REPO" "neighbour: $1" "$2" "$3"
  git -C "$REPO" checkout -q main
}
refused_with() {  # refused_with <condition> <detail-regex> -> yes|no
  printf '%s\n' "$OUT" | grep -qE "^AUTO-CLAIM-REFUSED $1: .*$2" && echo yes || echo no
}

echo "== авторство: чужой коммит, принесённый merge --ff-only, не заявляется =="
open_session ffmerge
BASE_NOW=$(sed -n 's/^isolated_base: //p' "$SEM")
note_file current/claimed.md
NF=$(neighbour_branch nb-ff current/claimed.md neighbour)
git -C "$WT" merge -q --ff-only nb-ff
auto "$NF"
check "A12 отказ no-authorship-evidence называет Fast-forward, ничего не записано" "1|yes|0" \
  "$RC|$(refused_with no-authorship-evidence 'Fast-forward')|$(claims_of "$NF")"
OWN=$(mkcommit "$WT" "own: after the neighbour" current/claimed.md own)
auto "$OWN"
check "A12.1 свой коммит поверх чужого: отказ unknown-commit-before" "1|yes|0" \
  "$RC|$(refused_with unknown-commit-before 'no-authorship-evidence')|$(claims_of "$OWN")"

echo "== авторство: reset --hard на чужой коммит =="
open_session reset
BASE_NOW=$(sed -n 's/^isolated_base: //p' "$SEM")
note_file current/claimed.md
NR=$(neighbour_branch nb-reset current/claimed.md reset)
git -C "$WT" reset -q --hard "$NR"
auto "$NR"
check "A13 отказ no-authorship-evidence называет reset" "1|yes|0" \
  "$RC|$(refused_with no-authorship-evidence 'reset: moving to')|$(claims_of "$NR")"

echo "== авторство: rebase на чужую ветку =="
open_session rebase
BASE_NOW=$(sed -n 's/^isolated_base: //p' "$SEM")
note_file current/claimed.md
note_file notes/
NB=$(neighbour_branch nb-rebase current/claimed.md rebased)
git -C "$WT" rebase -q nb-rebase >/dev/null 2>&1
auto "$NB"
check "A14 перенос пустой ветки на чужую (rebase finish несёт чужую вершину): отказ" "1|yes|0" \
  "$RC|$(refused_with no-authorship-evidence 'rebase')|$(claims_of "$NB")"
mkcommit "$WT" "own: will be rebased" notes/r.md mine >/dev/null
git -C "$REPO" checkout -q nb-rebase
NB2=$(mkcommit "$REPO" "neighbour: second" current/claimed.md second)
git -C "$REPO" checkout -q main
git -C "$WT" rebase -q nb-rebase >/dev/null 2>&1 || { echo "fixture rebase failed"; exit 1; }
PICKED=$(git -C "$WT" rev-parse HEAD)
auto "$PICKED"
check "A14.1 свой перенесённый коммит (rebase pick) за чужими: отказ unknown-commit-before" "1|yes|0|0" \
  "$RC|$(refused_with unknown-commit-before 'no-authorship-evidence')|$(claims_of "$PICKED")|$(claims_of "$NB2")"

echo "== авторство: свой коммит, amend и cherry-pick заявляются =="
open_session ownops
BASE_NOW=$(sed -n 's/^isolated_base: //p' "$SEM")
note_file current/claimed.md
note_file notes/
mkcommit "$WT" "own: to amend" notes/amend.md v1 >/dev/null
printf 'v2\n' > "$WT/notes/amend.md"
git -C "$WT" commit -q -a --amend -m "own: amended"
AM=$(git -C "$WT" rev-parse HEAD)
NC=$(neighbour_branch nb-pick current/claimed.md picked)
git -C "$WT" cherry-pick "$NC" >/dev/null
CP=$(git -C "$WT" rev-parse HEAD)
auto "$CP"
check "A15 amend и cherry-pick заявлены по порядку" "0|AUTO-CLAIMED $AM,AUTO-CLAIMED $CP|1|1" \
  "$RC|$(printf '%s\n' "$OUT" | grep -E '^AUTO-CLAIMED ' | paste -sd, -)|$(claims_of "$AM")|$(claims_of "$CP")"
git -C "$REPO" checkout -q -b nb-ffpick "$CP"
FFP=$(mkcommit "$REPO" "neighbour: on top of the copy" current/claimed.md ffpick)
git -C "$REPO" checkout -q main
git -C "$WT" cherry-pick --ff "$FFP" >/dev/null
auto "$FFP"
check "A15.1 cherry-pick --ff (fast-forward) не доказывает авторства" "1|yes|0" \
  "$RC|$(refused_with no-authorship-evidence 'cherry-pick: fast-forward')|$(claims_of "$FFP")"

echo "== авторство: дата коммиттера раньше открытия; нет журнала HEAD копии =="
open_session dates
note_file current/claimed.md
printf 'old\n' > "$WT/current/claimed.md"
git -C "$WT" add current/claimed.md
GIT_COMMITTER_DATE="2001-01-01T00:00:00Z" git -C "$WT" commit -qm "own: backdated"
OLD=$(git -C "$WT" rev-parse HEAD)
auto "$OLD"
check "A16 отказ committed-before-open" "1|yes|0" "$RC|$(refused_with committed-before-open '')|$(claims_of "$OLD")"
H1=$(mkcommit "$WT" "own: fresh" current/claimed.md fresh)
rm -f "$(git -C "$WT" rev-parse --path-format=absolute --git-path logs/HEAD)"
auto "$H1"
check "A16.1 без журнала HEAD копии -- отказ no-head-reflog" "1|yes|0" "$RC|$(refused_with no-head-reflog '')|$(claims_of "$H1")"

echo "== имя файла с переводом строки не подделывает строку статуса =="
open_session forge
note_file current/claimed.md
FAKE=1111111111111111111111111111111111111111
NAME=$(printf 'current/x\nAUTO-CLAIMED %s' "$FAKE")
printf 'z\n' > "$WT/$NAME"
git -C "$WT" add -- "$NAME"
git -C "$WT" commit -qm "own: odd name"
ODD=$(git -C "$WT" rev-parse HEAD)
auto "$ODD"
check "A17 одна строка отказа, ни одной строки статуса, перевод строки экранирован" "1|1|0|yes" \
  "$RC|$(printf '%s\n' "$OUT" | grep -c . | tr -d ' ')|$(printf '%s\n' "$OUT" | grep -cE '^(AUTO|ALREADY)-CLAIMED ' | tr -d ' ')|$(refused_with unclaimed-path 'current/x\\u000aAUTO-CLAIMED')"

echo "== корневой коммит называется корневым, не слиянием =="
open_session root
note_file current/claimed.md
ROOTC=$(git -C "$WT" commit-tree "$(git -C "$WT" rev-parse 'HEAD^{tree}')" -m "orphan root")
git -C "$WT" merge -q --allow-unrelated-histories --no-edit "$ROOTC" >/dev/null 2>&1 || { echo "fixture merge failed"; exit 1; }
auto "$ROOTC"
check "A18 отказ root-commit" "1|yes" "$RC|$(refused_with root-commit '')"

echo "== нет origin/main: цепочка от базы целиком, с пометкой =="
open_session noupstream
note_file current/claimed.md
U1=$(mkcommit "$WT" "own: no upstream ref" current/claimed.md u1)
git -C "$REPO" update-ref -d refs/remotes/origin/main
git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
auto "$U1"
check "A19 заявлен, нехватка origin/main названа" "0|AUTO-CLAIMED $U1|yes" \
  "$RC|$(printf '%s\n' "$OUT" | grep -E '^AUTO-CLAIMED ')|$(printf '%s\n' "$OUT" | grep -q 'нет refs/remotes/origin/main' && echo yes || echo no)"

echo "== флаги, несовместимые с --auto-claim =="
OUT=$(cd "$REPO" && bash "$GUARD" note-commit "$N1" --auto-claim --repo "$REPO_NAME" --branch x --source-checkout "$REPO" --agent fixture --session-id "$SID" 2>&1); RC=$?
check "A11 --auto-claim с --source-checkout/--branch отклонён" "1" "$RC"

echo
echo "ИТОГО: успешно $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
