#!/usr/bin/env bash
# session-guard-close-conversation-siblings-matrix-smoke.sh -- WP-484 Ф301 (inbox И-11, Ф221).
#
# The class of defect: a live semaphore with no terminal quick-close card and no armed
# close obligation had NO legal exit. It happened twice in three weeks (Ф221 on 21.10 with
# a single semaphore, И-11 on 11.11 with two semaphores of one conversation), and every fix
# patched one branch. The invariant checked here is the general one: for two live semaphores
# of ONE conversation and ONE work product, in whatever order they are closed, the pilot
# always has a way out, the refusal names it, and the way out never weakens the delivery
# proof of the work.
#
# Rows (G = semaphore opened by the WP Gate, close_path unknown; P = peer-session semaphore):
#   1. opening P next to a live G warns about G and its exits (layer 2);
#   2. P closes on its own declared path; G then refuses, and the refusal names --pilot-release;
#   3. an empty pilot word is refused;
#   4. the pilot's word does NOT bypass delivery: unpublished work still blocks the release;
#   5. with the work published, the pilot's word closes G and the word is kept in the audit log;
#   6. a plain close never succeeds by itself (the exit is the pilot's word, not a silent default).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="${SESSION_GUARD_UNDER_TEST:-$ROOT_DIR/scripts/session-guard.sh}"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-conversation-siblings.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/sessions" "$REPO/inbox/agent/tasks" "$REPO/scripts"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
cat > "$REPO/scripts/process-runner.py" <<'EOF'
#!/usr/bin/env python3
print("{}")
EOF
chmod +x "$REPO/scripts/process-runner.py"
git -C "$REPO" add scripts/process-runner.py
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""

PASS=0
FAIL=0
check() {  # <name> <got> <expected>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "  ПРОВАЛ: $1 (ожидал '$3', получил '$2')"
  fi
}

write_orz() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
---
date: 2026-11-11
type: work
wp: WP-484
duration_h: 0.1
artifacts: []
agent: fixture
---

# Fixture session

## Главный инсайт
fixture

## Контекст
fixture

## Достигнуто
fixture

## Ключевые решения
fixture
EOF
}

# open_sem <conversation> <slug> <publish: yes|no> [extra open args...] -> opens, writes and commits
# the ORZ file of the new semaphore, optionally publishes it. stderr of `open` goes to $OPEN_ERR.
OPEN_ERR="$TEST_ROOT/open.err"
open_sem() {
  local conversation="$1" slug="$2" publish="$3"
  shift 3
  CLAUDE_CODE_SESSION_ID="$conversation" bash "$GUARD" open --wp WP-484 --task fixture \
    --slug "$slug" --agent fixture "$@" >/dev/null 2>"$OPEN_ERR"
  local semaphore orz
  semaphore=$(grep -l "^slug: $slug\$" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
  orz=$(grep '^orz_file: ' "$semaphore" | cut -d' ' -f2-)
  write_orz "$REPO/sessions/$orz"
  git -C "$REPO" add "sessions/$orz"
  git -C "$REPO" commit -qm "orz $slug"
  if [ "$publish" = yes ]; then
    git -C "$REPO" push -q origin HEAD:main
  fi
}

# close_sem <conversation> <slug> [extra close args...] -> prints the exit code; stderr in $CLOSE_ERR
CLOSE_ERR="$TEST_ROOT/close.err"
close_sem() {
  local conversation="$1" slug="$2" rc=0
  shift 2
  CLAUDE_CODE_SESSION_ID="$conversation" bash "$GUARD" close --wp WP-484 --slug "$slug" \
    --agent fixture "$@" >/dev/null 2>"$CLOSE_ERR" || rc=$?
  echo "$rc"
}

CONV="convo-siblings"

echo "1. второе открытие рядом с живой отметкой той же беседы предупреждает о ней"
open_sem "$CONV" siblings-gate no
G_OPEN_WARNED=no
grep -q 'уже есть живая отметка' "$OPEN_ERR" && G_OPEN_WARNED=yes
check "первое открытие в беседе без предупреждения" "$G_OPEN_WARNED" "no"
open_sem "$CONV" siblings-peer no --close-path peer-session
P_OPEN_WARNED=no
grep -q "уже есть живая отметка 'siblings-gate'" "$OPEN_ERR" && P_OPEN_WARNED=yes
check "второе открытие называет живую отметку siblings-gate" "$P_OPEN_WARNED" "yes"
P_NAMES_EXIT=no
grep -q 'close --slug siblings-gate' "$OPEN_ERR" && P_NAMES_EXIT=yes
check "предупреждение называет команду закрытия" "$P_NAMES_EXIT" "yes"

echo "2. peer закрывается по своему пути; G отказывает и называет выход"
git -C "$REPO" push -q origin HEAD:main
RC_PEER=$(close_sem "$CONV" siblings-peer)
check "peer-отметка закрылась по объявленному пути" "$RC_PEER" "0"
RC_G_PLAIN=$(close_sem "$CONV" siblings-gate)
check "G без слова пилота не закрывается сама" "$RC_G_PLAIN" "7"
G_REFUSAL_NAMES_EXIT=no
grep -q -- '--pilot-release' "$CLOSE_ERR" && G_REFUSAL_NAMES_EXIT=yes
check "отказ называет выход --pilot-release" "$G_REFUSAL_NAMES_EXIT" "yes"

echo "3. пустое слово пилота отклоняется"
RC_EMPTY=$(close_sem "$CONV" siblings-gate --pilot-release "")
check "пустое слово даёт отказ с кодом 1" "$RC_EMPTY" "1"

echo "4. слово пилота не ослабляет проверку доставки"
# The ORZ file of G was committed in row 1 but is not on origin yet only if it was never
# pushed; make a fresh unpublished commit so that the proof has something to refuse.
orz_g=$(grep '^orz_file: ' "$(grep -l '^slug: siblings-gate$' "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)" | cut -d' ' -f2-)
printf '\nunpublished tail\n' >> "$REPO/sessions/$orz_g"
git -C "$REPO" add "sessions/$orz_g"
git -C "$REPO" commit -qm "unpublished change of G"
RC_UNPUBLISHED=$(close_sem "$CONV" siblings-gate --pilot-release "закрой, работа опубликована")
check "неопубликованное изменение блокирует и закрытие по слову" "$RC_UNPUBLISHED" "7"
DELIVERY_REFUSED=no
grep -q 'delivery не подтверждена' "$CLOSE_ERR" && DELIVERY_REFUSED=yes
check "причина отказа — неподтверждённая доставка, а не другой отказ" "$DELIVERY_REFUSED" "yes"

echo "5. работа опубликована: слово пилота закрывает G и остаётся в журнале"
git -C "$REPO" push -q origin HEAD:main
RC_RELEASE=$(close_sem "$CONV" siblings-gate --pilot-release "закрой без Quick Close, работа опубликована")
check "G закрылась по слову пилота" "$RC_RELEASE" "0"
RELEASE_ANNOUNCED=no
grep -q 'по явному слову пилота' "$CLOSE_ERR" && RELEASE_ANNOUNCED=yes
check "закрытие объявило канал вслух" "$RELEASE_ANNOUNCED" "yes"
AUDIT="$TEST_ROOT/.iwe-runtime/pilot-release-audit.jsonl"
WORD_LOGGED=no
grep -q 'закрой без Quick Close, работа опубликована' "$AUDIT" 2>/dev/null && WORD_LOGGED=yes
check "слово пилота записано в pilot-release-audit.jsonl" "$WORD_LOGGED" "yes"
OPEN_LEFT=$( (ls "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open 2>/dev/null || true) | wc -l | tr -d ' ')
check "живых отметок в беседе не осталось" "$OPEN_LEFT" "0"

echo "6. закрытие без слова пилота никогда не проходит само (обход Quick Close не стал значением по умолчанию)"
CONV2="convo-siblings-plain"
open_sem "$CONV2" siblings-plain yes
RC_PLAIN=$(close_sem "$CONV2" siblings-plain)
check "одиночная отметка без карточки и без слова не закрывается" "$RC_PLAIN" "7"

echo
echo "session-guard-close-conversation-siblings-matrix-smoke: прошло $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
