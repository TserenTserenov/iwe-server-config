#!/usr/bin/env bash
# wp-handoff-peer-check-smoke.sh -- WP-484 F257 M2: the peer-session close path
# checks the card field «Следующий шаг» in shadow mode.  Disposable repo and
# semaphore only; pins the contract: warns on a bad field, logs every run, never
# blocks, treats missing infrastructure as `infra`, not as a violation.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
CHECKER_SRC="${IWE_HANDOFF_CHECKER_SRC:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/wp-handoff-check.py}"
if [ ! -f "$CHECKER_SRC" ]; then
  echo "SKIP: wp-handoff-check.py не найден ($CHECKER_SRC); задать IWE_HANDOFF_CHECKER_SRC"
  exit 0
fi
CHECK="$SCRIPTS/wp-handoff-peer-check.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
has() { printf '%s' "$1" | grep -qF -- "$2" && ok || bad "$3 (нет: $2) в: $1"; }
lacks() { printf '%s' "$1" | grep -qF -- "$2" && bad "$3 (лишнее: $2)" || ok; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wp-handoff-peer-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
IWE="$TMP/iwe"
GOV="$TMP/gov"
mkdir -p "$IWE/.iwe-runtime/sessions" "$GOV/inbox/WP-9" "$GOV/scripts"
git init -q "$GOV"
git -C "$GOV" config user.email t@example.com
git -C "$GOV" config user.name test
cp "$CHECKER_SRC" "$GOV/scripts/wp-handoff-check.py"

write_card() { # <next step text>
  cat >"$GOV/inbox/WP-9/WP-9.md" <<CARD
---
wp: 9
phases:
  Ф1: in_progress
---

# Карточка

## Осталось

**Следующий шаг:** $1
**Актуально до:** 30.10
→ memory: none

## Закрытие
CARD
}

OLD_OID=""
write_card "Ф1 — старое действие"
OLD_OID="$(git -C "$GOV" hash-object -w "$GOV/inbox/WP-9/WP-9.md")"

make_sem() { # <close_path> [with-baseline]
  local close_path="$1" baseline="${2:-}"
  {
    echo "---"
    echo "agent: claude-code"
    echo "wp: WP-9"
    echo "slug: s1"
    echo "session_id: s1"
    echo "close_path: $close_path"
    echo "governance_worktree: $GOV"
    [ -n "$baseline" ] && echo "baseline_card_oid: $OLD_OID"
  } >"$IWE/.iwe-runtime/sessions/claude-code-s1.open"
}
run() { IWE_ROOT="$IWE" bash "$CHECK" "$@" 2>&1; echo "rc=$?"; }
LOG="$IWE/.iwe-runtime/handoff-check-shadow.log"

# 1. good field, changed against the baseline -> pass, logged, rc 0
write_card "Ф1 — новое действие: проверить хук"
make_sem peer-session with-baseline
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "rc=0" "норма: код возврата 0"
has "$OUT" "проверено" "норма: сообщение о проверке"
has "$(cat "$LOG")" "| pass | HANDOFF_OK |" "норма: запись в журнале наблюдения"
has "$(cat "$LOG")" "card_digest" "норма: отпечаток ревизии в журнале"

# 2. field unchanged since the baseline -> fail warning, still rc 0
write_card "Ф1 — старое действие"
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "режим наблюдения" "не изменилось: предупреждение"
has "$OUT" "HANDOFF_UNCHANGED" "не изменилось: код"
has "$OUT" "rc=0" "не изменилось: закрытие не блокируется"

# 3. stock phrase -> fail
write_card "продолжай по плану"
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "HANDOFF_STOPLIST" "стоп-фраза"

# 4. no phase named while a phase is open -> fail
write_card "Сделать что-то конкретное"
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "HANDOFF_NO_PHASE_NAMED" "фаза не названа"

# 5. no baseline recorded -> still checks, baseline reported unavailable
write_card "Ф1 — новое действие: проверить хук"
make_sem peer-session
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "проверено" "без baseline: проверка идёт"
has "$(tail -1 "$LOG")" '"origin_baseline": "unavailable"' "без baseline: честно помечено"

# 6. lookup by agent and slug
OUT="$(run --agent claude-code --slug s1)"
has "$OUT" "проверено" "поиск семафора по агенту и слагу"

# 6b. lookup by agent and WP: exactly one peer-session semaphore -> used; two -> ambiguous
write_card "Ф1 — новое действие: проверить хук"
make_sem peer-session with-baseline
OUT="$(run --agent claude-code --wp WP-9)"
has "$OUT" "проверено" "поиск по агенту и РП"
sed 's/^close_path: .*/close_path: unknown/' "$IWE/.iwe-runtime/sessions/claude-code-s1.open" >"$TMP/k.tmp" \
  && mv "$TMP/k.tmp" "$IWE/.iwe-runtime/sessions/claude-code-s1.open"
OUT="$(run --agent claude-code --wp WP-9)"
has "$OUT" "проверено" "поиск по РП работает и без close_path=peer-session (Kimi)"
make_sem peer-session with-baseline
sed 's/^slug: s1$/slug: s2/; s/^session_id: s1$/session_id: s2/' "$IWE/.iwe-runtime/sessions/claude-code-s1.open" \
  >"$IWE/.iwe-runtime/sessions/claude-code-s2.open"
OUT="$(run --agent claude-code --wp WP-9)"
has "$OUT" "rc=0" "два семафора: код 0"
has "$(tail -1 "$LOG")" "| infra | SEMAPHORE_AMBIGUOUS |" "два семафора: неоднозначность, не угадывание"
rm -f "$IWE/.iwe-runtime/sessions/claude-code-s2.open"

# 7. not a peer session -> nothing printed, nothing logged
LINES_BEFORE="$(wc -l <"$LOG" | tr -d ' ')"
make_sem pipeline
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
lacks "$OUT" "Session CLOSE" "не пир-сессия: тишина"
[ "$(wc -l <"$LOG" | tr -d ' ')" = "$LINES_BEFORE" ] && ok || bad "не пир-сессия: журнал не должен расти"

# 8. mode off -> nothing
make_sem peer-session
LINES_BEFORE="$(wc -l <"$LOG" | tr -d ' ')"
OUT="$(IWE_HANDOFF_CHECK_MODE=off IWE_ROOT="$IWE" bash "$CHECK" --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open" 2>&1; echo "rc=$?")"
has "$OUT" "rc=0" "off: код 0"
[ "$(wc -l <"$LOG" | tr -d ' ')" = "$LINES_BEFORE" ] && ok || bad "off: журнал не должен расти"

# 9. infrastructure problems are `infra`, not a verdict
rm -f "$GOV/inbox/WP-9/WP-9.md"
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "rc=0" "нет карточки: код 0"
has "$(tail -1 "$LOG")" "| infra | CARD_MISSING |" "нет карточки: infra"
lacks "$OUT" "не прошло проверку" "нет карточки: не нарушение"
OUT="$(run --agent claude-code --slug no-such-slug)"
has "$OUT" "rc=0" "нет семафора: код 0"
has "$(tail -1 "$LOG")" "| infra | SEMAPHORE_NOT_FOUND |" "нет семафора: infra"

# 10. flag without a value does not spin; invalid baseline id is `infra`, not used
OUT="$(timeout 10 bash "$CHECK" --sem 2>&1; echo "rc=$?")"
has "$OUT" "rc=0" "флаг без значения: не зависает"
write_card "Ф1 — новое действие: проверить хук"
make_sem peer-session with-baseline
sed 's/^baseline_card_oid: .*/baseline_card_oid: -p/' "$IWE/.iwe-runtime/sessions/claude-code-s1.open" >"$TMP/sem.tmp" \
  && mv "$TMP/sem.tmp" "$IWE/.iwe-runtime/sessions/claude-code-s1.open"
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$(cat "$LOG")" "| infra | BASELINE_OID_INVALID |" "плохой хэш: infra"
has "$OUT" "rc=0" "плохой хэш: код 0"

# 11. a stale checker without `peer` mode reads stdin; the check must not hang
make_sem peer-session
printf 'import sys\nsys.stdin.read()\n' >"$GOV/scripts/wp-handoff-check.py"
OUT="$( (sleep 30 | timeout 25 env IWE_ROOT="$IWE" bash "$CHECK" --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open") 2>&1; echo "rc=$?")"
has "$OUT" "rc=0" "устаревший проверяльщик: закрытие не виснет"
cp "$CHECKER_SRC" "$GOV/scripts/wp-handoff-check.py"

# 11b. a checker that prints something that is not `state=.. code=.. evidence=..` is an
#      infrastructure problem in the log, never a verdict parsed from garbage
make_sem peer-session
printf 'print("всё хорошо")\n' >"$GOV/scripts/wp-handoff-check.py"
: >"$LOG"
run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open" >/dev/null
LAST="$(tail -1 "$LOG")"
has "$LAST" "| infra | CHECKER_OUTPUT_UNPARSEABLE |" "мусорный вывод чекера: infra, не вердикт"
cp "$CHECKER_SRC" "$GOV/scripts/wp-handoff-check.py"

# 12. evidence with a pipe does not shift log fields; session id is logged
write_card "Ф1 | с чертой"
make_sem peer-session with-baseline
run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open" >/dev/null
LAST="$(tail -1 "$LOG")"
[ "$(printf '%s' "$LAST" | awk -F' [|] ' '{print NF}')" = 6 ] && ok || bad "черта в evidence сдвинула поля: $LAST"
has "$LAST" "| s1 |" "в журнале id сессии"

# 13. a card edit that is not on origin yet is called out (state itself unchanged)
git init -q --bare "$TMP/origin.git"
git -C "$GOV" remote add origin "$TMP/origin.git" 2>/dev/null
write_card "Ф1 — опубликованное значение"
git -C "$GOV" add -A && git -C "$GOV" commit -q -m card
git -C "$GOV" push -q origin HEAD:main 2>/dev/null
git -C "$GOV" fetch -q origin 2>/dev/null
make_sem peer-session with-baseline
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
lacks "$OUT" "ещё не опубликована на origin" "карточка совпадает с origin: без предупреждения"
write_card "Ф1 — новое значение, ещё не опубликовано"
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "ещё не опубликована на origin" "правка не на origin: предупреждение"
has "$(tail -1 "$LOG")" '"not_on_origin": true' "правка не на origin: пометка в журнале"

# 13b. a baseline recorded without the open-time fetch is flagged in the log and on stderr
make_sem peer-session with-baseline
sed -i.bak '/^baseline_card_oid:/a\
baseline_source: local-unfetched' "$IWE/.iwe-runtime/sessions/claude-code-s1.open" && rm -f "$IWE/.iwe-runtime/sessions/claude-code-s1.open.bak"
OUT="$(run --sem "$IWE/.iwe-runtime/sessions/claude-code-s1.open")"
has "$OUT" "без свежего fetch" "baseline без fetch: предупреждение"
has "$(tail -1 "$LOG")" '"baseline_source": "local-unfetched"' "baseline без fetch: пометка в журнале"

# 14. the two insertions in session-guard.sh are still there (open records the baseline, close calls the check)
SG="$SCRIPTS/session-guard.sh"
grep -q 'echo "baseline_card_oid: \$BASELINE_CARD_OID"' "$SG" && ok || bad "open не записывает baseline_card_oid"
grep -q 'echo "baseline_source: \$BASELINE_SOURCE"' "$SG" && ok || bad "open не записывает baseline_source"
grep -q 'fetch -q origin main </dev/null' "$SG" && ok || bad "open не делает ограниченный fetch перед baseline"
grep -q 'wp-handoff-peer-check.sh" --sem "\$SEM_FILE"' "$SG" && ok || bad "close не вызывает проверку пути пир-сессии"
grep -q "grep -qx 'close_path: peer-session'" "$SG" && ok || bad "close вызывает проверку не только для пир-сессий"

echo "wp-handoff-peer-check smoke: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
