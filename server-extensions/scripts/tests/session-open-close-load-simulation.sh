#!/bin/bash
# session-open-close-load-simulation.sh [N-sessions] [--wave A|B]
#
# WP-530 Ф14 (21.08, peer-session with Kimi,
# sessions/2026-08/21/2026-08-21-11-wp530-linija3-load-run/): Line 3 of the
# WP-484 "0 -> F'" package (Ф123/Ф124) -- load-test session-guard.sh open
# --isolate AND close together, not just open. WP-530 Ф4 (16.08) already
# proved open --isolate at N=8..20 (60/60 exit 0), but that run predates the
# three close-path bugs fixed this morning (WP-484 Ф125, 07:56-08:29): Ф119
# (ROOT resolved from __file__ instead of cwd), Ф121 (witness lost the
# pilot's reflection answer between runs), Ф122-class (a blocking close step
# failed with bare stderr, no machine-readable JSON reason). None of those
# are exercisable by an open-only run.
#
# Consensus with Kimi (turn 2, CONSENSUS: reached): decompose into layer T
# (transport = open --isolate, already proven by Ф4, untouched here) and
# layer S (close-path semantics = this script). Ф119/Ф122 are structural --
# they fire on filesystem/process shape, not on what a session actually
# works on -- so a synthetic minimal close is representative for them. Ф121
# needs a live pilot answering a reflection question with real run-to-run
# variability; a throwaway sandbox with N unattended workers can't reproduce
# that, and this script does not try to -- each worker declares
# --close-path peer-session at open (session-guard.sh:1954), the same
# legitimate bypass a real peer-conversation session uses, which skips the
# reflection gate entirely rather than answering it. That means this run
# exercises zero of the witness/RENDERED_AT machinery Ф121 actually lives
# in. Anyone reading the metrics this script reports should not read a clean
# run as evidence Ф121 is covered at scale; it isn't covered at all here.
#
# ds-publish-peer-load-simulation.sh (WP-530 Ф7/Ф8) already covers the
# concurrent-push slice of the close path (disjoint-target scenario, 20/20
# without a retry-wrapper) -- not duplicated here. This script's job is the
# session-guard.sh open+close mechanics: semaphore lifecycle, ORZ validation,
# and the three Ф125 fixes.
#
# Metrics reported (WP-484 Ф123, applied as given, not redefined here):
#   P0 = share of Quick Close (close call) taking >30s        (gate: <5%)
#   P1 = share of close runs ending in an infrastructure PENDING (gate: <10%)
#   S0 = median seconds from open to a completed close          (gate: <30min --
#        every run here is well under that; reported for completeness, not
#        because this synthetic path is expected to approach the threshold)
#   L0 = new "close is broken" failure classes surfaced          (gate: =0)
# S1 (orphaned debt >24h) and the R23-verdict-streak criterion are WP-541's
# metric to interpret, not this script's -- see report for what's handed off
# raw instead of pre-classified green/red.
set -uo pipefail

N=15
WAVE="A"
while [ $# -gt 0 ]; do
  case "$1" in
    --wave) WAVE="$2"; shift 2 ;;
    *) N="$1"; shift ;;
  esac
done
case "$WAVE" in
  A|B) ;;
  *) echo "FAIL: --wave must be A or B, got '$WAVE'"; exit 1 ;;
esac
# BSD seq on N<=0 still emits values (seq 1 0 -> "1", seq 1 -3 -> "1 0 -1 -2
# -3") instead of an empty range -- without this check the worker loop below
# silently ran anyway and the final SUM-vs-N assertion failed with a
# misleading message instead of the actual cause. Found by cold-context
# review (2026-08-21).
case "$N" in
  ''|*[!0-9]*) echo "FAIL: N must be a positive integer, got '$N'"; exit 1 ;;
esac
[ "$N" -gt 0 ] || { echo "FAIL: N must be a positive integer, got '$N'"; exit 1; }

SESSION_GUARD="${SESSION_GUARD_UNDER_TEST:-$HOME/IWE/scripts/session-guard.sh}"
[ -x "$SESSION_GUARD" ] || { echo "FAIL: $SESSION_GUARD not found/executable"; exit 1; }

# --wave B reuses $KEEP_ROOT from a prior --wave A run (same sandbox, same
# accumulated worktrees/semaphores) to separate "does scale alone break it"
# from "does accumulated dirt over two rounds break it" -- the same A/B
# split Ф4 used on the open-only run, Codex's original point there still
# applies here: a single green wave is not proof against a lucky ordering of
# concurrent starts.
if [ "$WAVE" = "B" ] && [ -n "${KEEP_ROOT:-}" ] && [ -d "$KEEP_ROOT" ]; then
  ROOT="$KEEP_ROOT"
else
  ROOT=$(mktemp -d)
fi
[ -n "${KEEP_ROOT:-}" ] || trap 'rm -rf "$ROOT"' EXIT

ORIGIN="$ROOT/origin.git"
GOV_NAME="sandbox-governance"
SEED="$ROOT/$GOV_NAME"

if [ ! -d "$ORIGIN" ]; then
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$SEED"
  git -C "$SEED" config user.email test@test
  git -C "$SEED" config user.name test
  # Governance-repo markers _resolve_root() (WP-484 Ф119/Ф125) checks for --
  # without these, process-runner.py-driven close paths fail on "not a
  # governance repo" before reaching the three bugs this run exists to
  # exercise.
  mkdir -p "$SEED/docs" "$SEED/inbox" "$SEED/scripts/processes" "$SEED/sessions" "$SEED/current"
  echo "| # | P | Название | Ст | Репо | Ставка | Бюджет | Комментарий |" > "$SEED/docs/WP-REGISTRY.md"
  echo "|---|---|----------|----|----|--------|--------|-------------|" >> "$SEED/docs/WP-REGISTRY.md"
  echo "| 900 | P3 | Sandbox load-test card | 🔄 | test | — | 1h | — |" >> "$SEED/docs/WP-REGISTRY.md"

  # session-guard.sh close's own audit_runner_cards() (session-guard.sh:1817)
  # shells out to a real process-runner.py -- found live (2026-08-21, first
  # smoke run): every close failed with rc=7 because this directory had only
  # marker files, no actual script, so `python3 .../process-runner.py
  # audit-cards` errored with "No such file or directory" before it could
  # even run its own logic. Copying the real files (not a stub) means this
  # run also exercises the Ф119 fix itself (_resolve_root() in
  # process-runner.py, WP-484 Ф125) on an isolated worktree, not just
  # session-guard.sh's half of it. iwe_gate.py is process-runner.py's only
  # local import (sys.path.insert(0, Path(__file__).parent) --
  # process-runner.py:56) and needs to sit next to it for that import to
  # resolve; both are stdlib+PyYAML only, no further copying needed.
  cp "$HOME/IWE/DS-my-strategy/scripts/process-runner.py" "$SEED/scripts/process-runner.py"
  cp "$HOME/IWE/DS-my-strategy/scripts/iwe_gate.py" "$SEED/scripts/iwe_gate.py"
  git -C "$SEED" add docs inbox scripts sessions current
  git -C "$SEED" commit -q -m seed
  git -C "$SEED" push -q "$ORIGIN" main
fi

export IWE_ROOT="$ROOT"
export IWE_GOVERNANCE_REPO="$GOV_NAME"
export IWE_AGENT="claude-code"

# One results.log per invocation, not per ROOT: --wave B with a reused
# KEEP_ROOT (deliberately, to test scale-plus-accumulated-dirt together --
# see the A/B split comment above) inherits wave A's leftover results.log
# from the SAME file otherwise, doubling every count and every worker id.
# Found live (2026-08-21): the final SUM-vs-N assertion correctly caught it
# (SUM=40 != N=20) rather than silently reporting wrong metrics, but the
# metrics themselves (close attempted: 40) were still bogus until this was
# in place -- `> "$ROOT/results.log"` here truncates any prior content
# before this run's workers start writing.
: > "$ROOT/results.log"

worker() {  # worker <i>
  local i="$1"
  local log="$ROOT/worker-$i.log"
  local slug="loadtest-w${i}-wave${WAVE}"

  # `open --isolate` resolves ISOLATE_BASE_DIR from `git rev-parse
  # --show-toplevel` on the CALLING PROCESS's actual cwd (session-guard.sh:
  # 1113), deliberately -- not from IWE_ROOT/IWE_GOVERNANCE_REPO -- so this
  # test's env overrides alone don't put it in the sandbox. Each simulated
  # session needs its own real checkout to call `open --isolate` from, the
  # same way a real agent session does; sharing $SEED directly across N
  # parallel `cd`s would race workers against each other's cwd. Found live
  # (2026-08-21): the first version called `open --isolate` from whatever
  # directory this script's own caller happened to be in, which resolved to
  # a dirty, unrelated real repo and refused every single open with "есть
  # незакоммиченные изменения" before any sandbox logic ran.
  local caller_dir="$ROOT/caller-$i"
  git clone -q "$SEED" "$caller_dir" >>"$log" 2>&1
  git -C "$caller_dir" config user.email "worker-$i@test"
  git -C "$caller_dir" config user.name "worker-$i"

  local t_open_start t_open_end t_close_start t_close_end rc_open rc_close
  t_open_start=$(date +%s)
  local open_out
  # --close-path peer-session (session-guard.sh:1954) declares up front that
  # this session's close protocol is a direct commit, not the quick-close
  # runner -- it sets RUNNER_OK before the RUN-quick-close-card search even
  # runs, so close below needs no --force-no-reflection and no synthetic
  # runner card. Found by cold-context review (2026-08-21): the first draft
  # used --force-no-reflection expecting it alone to bypass the reflection
  # gate, but that flag still requires a RUN-quick-close-*.md card with
  # current_step=blocked-witness-unavailable (session-guard.sh:2061) that
  # this script never creates -- every close call failed with exit 7.
  open_out=$(cd "$caller_dir" && bash "$SESSION_GUARD" open --wp "WP-900" --agent claude-code \
    --isolate --close-path peer-session --slug "$slug" \
    --task "sandbox load test worker $i wave $WAVE" \
    2>>"$log")
  rc_open=$?
  t_open_end=$(date +%s)

  if [ "$rc_open" -ne 0 ]; then
    echo "$i open_failed rc=$rc_open dur=$((t_open_end - t_open_start))s" >> "$ROOT/results.log"
    return
  fi

  # `open --isolate` prints the JSON worktree descriptor first
  # (session-guard.sh:1378) but keeps writing two more plain-text stdout
  # lines afterward ("ORZ scaffold создан: ...", "Session OPEN: ...",
  # session-guard.sh:1584/1607) -- json.load on the full capture throws
  # "Extra data" on every call. Only the first line is JSON. Found by
  # cold-context review (2026-08-21), reproduced live.
  local wt_path
  wt_path=$(echo "$open_out" | head -1 | python3 -c "import sys,json; print(json.load(sys.stdin)['worktree_path'])" 2>>"$log")
  if [ -z "$wt_path" ] || [ ! -d "$wt_path" ]; then
    echo "$i open_ok_but_no_worktree dur=$((t_open_end - t_open_start))s" >> "$ROOT/results.log"
    return
  fi

  # ORZ scaffold that `open` already wrote is at a predictable path (same
  # formula session-guard.sh itself uses -- see peer-conversation/SKILL.md
  # Шаг 4.4 for the same derivation on the writer side). Fill required
  # frontmatter/sections (validate_orz, session-guard.sh:1612) and commit it
  # -- close refuses an ORZ file that isn't git-tracked.
  local orz_file="$wt_path/sessions/2026-08/2026-08-21-${slug}.md"
  cat > "$orz_file" <<EOF
---
date: 2026-08-21
type: session
wp: WP-900
agent: claude-code
duration_h: 0.0
artifacts: [sandbox-load-test]
---

## Главный инсайт

Synthetic sandbox load-test worker $i, wave $WAVE.

## Контекст

WP-530 Ф14 close-path load simulation.

## Достигнуто

| Артефакт | Описание |
|----------|----------|
| — | synthetic |

## Ключевые решения

—
EOF
  git -C "$wt_path" add "sessions/2026-08/2026-08-21-${slug}.md" >>"$log" 2>&1
  git -C "$wt_path" commit -q -m "sandbox load-test worker $i" >>"$log" 2>&1

  t_close_start=$(date +%s)
  local close_out
  close_out=$(cd "$wt_path" && bash "$SESSION_GUARD" close --wp "WP-900" --slug "$slug" \
    2>>"$log")
  rc_close=$?
  t_close_end=$(date +%s)

  local close_dur=$((t_close_end - t_close_start))
  local total_dur=$((t_close_end - t_open_start))

  if [ "$rc_close" -eq 0 ]; then
    if echo "$close_out" | grep -qi "PENDING"; then
      echo "$i closed_with_pending close_dur=${close_dur}s total_dur=${total_dur}s" >> "$ROOT/results.log"
    else
      echo "$i closed_clean close_dur=${close_dur}s total_dur=${total_dur}s" >> "$ROOT/results.log"
    fi
  else
    echo "$i close_failed rc=$rc_close close_dur=${close_dur}s total_dur=${total_dur}s" >> "$ROOT/results.log"
  fi
}

echo "=== Волна $WAVE: $N сессий, open --isolate -> commit ORZ -> close ==="
for i in $(seq 1 "$N"); do
  worker "$i" &
done
wait

echo "=== Итог по сессиям (wave=$WAVE) ==="
[ -f "$ROOT/results.log" ] || : > "$ROOT/results.log"
sort -n "$ROOT/results.log"

CLOSED_CLEAN=$(grep -c closed_clean "$ROOT/results.log" || true)
CLOSED_PENDING=$(grep -c closed_with_pending "$ROOT/results.log" || true)
CLOSE_FAILED=$(grep -c close_failed "$ROOT/results.log" || true)
OPEN_FAILED=$(grep -c open_failed "$ROOT/results.log" || true)
NO_WORKTREE=$(grep -c open_ok_but_no_worktree "$ROOT/results.log" || true)
CLOSE_ATTEMPTED=$((CLOSED_CLEAN + CLOSED_PENDING + CLOSE_FAILED))

# P0: share of close calls (attempted, i.e. reached the close step) whose
# close_dur exceeded 30s.
# `awk match($0, ..., a)` (3-arg match with a capture array) is a gawk
# extension -- BSD awk (macOS default, no gawk installed) throws a syntax
# error on it and the original version silently returned an empty P0/S0 on
# every run instead of failing loud. sed -nE with a substitution-to-capture
# is POSIX and behaves the same on both. Found by cold-context review
# (2026-08-21), reproduced live on this machine.
P0_SLOW=0
if [ "$CLOSE_ATTEMPTED" -gt 0 ]; then
  P0_SLOW=$(sed -nE 's/.*close_dur=([0-9]+)s.*/\1/p' "$ROOT/results.log" | awk '{ if ($1+0 > 30) c++ } END{print c+0}')
fi

echo ""
echo "=== Метрики гейта (WP-484 Ф123/Ф124, wave=$WAVE, N=$N) ==="
echo "открытий: $N, open_failed: $OPEN_FAILED, open_ok_but_no_worktree: $NO_WORKTREE"
echo "close попыток: $CLOSE_ATTEMPTED (closed_clean: $CLOSED_CLEAN, closed_with_pending: $CLOSED_PENDING, close_failed: $CLOSE_FAILED)"
if [ "$CLOSE_ATTEMPTED" -gt 0 ]; then
  P0_PCT=$(awk -v s="$P0_SLOW" -v t="$CLOSE_ATTEMPTED" 'BEGIN{printf "%.1f", (s/t)*100}')
  P1_PCT=$(awk -v p="$CLOSED_PENDING" -v t="$CLOSE_ATTEMPTED" 'BEGIN{printf "%.1f", (p/t)*100}')
  echo "P0 (доля close >30с): ${P0_PCT}% (порог <5%) -- $P0_SLOW из $CLOSE_ATTEMPTED"
  echo "P1 (доля close с инфраструктурным PENDING): ${P1_PCT}% (порог <10%) -- $CLOSED_PENDING из $CLOSE_ATTEMPTED"
else
  echo "P0/P1: н/п -- ни одна сессия не дошла до close (open_failed=$OPEN_FAILED)"
fi

if [ "$CLOSED_CLEAN" -gt 0 ] || [ "$CLOSED_PENDING" -gt 0 ]; then
  S0_MEDIAN=$(sed -nE 's/.*total_dur=([0-9]+)s.*/\1/p' "$ROOT/results.log" | sort -n | awk '{a[NR]=$1} END{ if (NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }')
  echo "S0 (медиана open->close, сек): $S0_MEDIAN (порог <30 мин = 1800с)"
fi

echo ""
echo "L0 (новые классы отказа close, не входящие в open_failed/closed_with_pending/close_failed): 0 при отсутствии строк вне этих категорий выше -- проверить results.log вручную, если сумма категорий != $N"

echo ""
echo "S1 и \"R23-подряд\" -- НЕ интерпретируются этим скриптом (консенсус с Kimi, WP-530 Ф14 turn 2): сырые данные ниже переданы WP-541 для оценки по критериям S-59."
echo "raw results: $ROOT/results.log"
if [ -n "${KEEP_ROOT:-}" ]; then
  echo "KEEP_ROOT задан -- sandbox сохранён в $ROOT для волны B / ручного разбора"
fi

SUM=$((CLOSED_CLEAN + CLOSED_PENDING + CLOSE_FAILED + OPEN_FAILED + NO_WORKTREE))
if [ "$SUM" -ne "$N" ]; then
  echo ""
  echo "FAIL: сумма категорий ($SUM) != N ($N) -- есть строки results.log вне известных категорий (см. L0 выше)"
  exit 1
fi

[ "$CLOSE_FAILED" -eq 0 ] && [ "$OPEN_FAILED" -eq 0 ] && [ "$NO_WORKTREE" -eq 0 ]
