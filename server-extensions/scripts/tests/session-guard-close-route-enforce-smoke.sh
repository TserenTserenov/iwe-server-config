#!/usr/bin/env bash
# Regression for WP-561 Ф61 stage 2: with the switch on, close executes the
# fact-based route instead of the close_path declared at open (pilot decision
# 15.11, one close path):
#   - every session with changes needs the runner, a peer session too -- even one
#     that changed only its journal and WP card (the former short peer close
#     skipped phase and WP archiving);
#   - a declared peer-session without a real journal (the 15.11 class) needs the
#     runner, or is released when its isolated copy is proven empty;
#   - with the switch off nothing changes (the declared bypass still works);
#   - a resumed close keeps the decision frozen at its first attempt.
# The classifier is unit-tested in test_close_route.py. All artifacts live in
# mktemp; nothing real is touched.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-close-route-enforce.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/inbox/WP-561" "$REPO/scripts"
printf '%s\n' 'hypothesis_relation: "tests"' > "$REPO/inbox/WP-561/WP-561.md"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
printf '%s\n' 'open-sessions.log' > "$REPO/.gitignore"
printf '%s\n' '#!/usr/bin/env python3' 'print("{}")' > "$REPO/scripts/process-runner.py"
LEDGER_LOG="$TEST_ROOT/ledger-calls.log"
cat > "$REPO/scripts/ledger-append.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LEDGER_LOG"
EOF
# Records every call; the real cancel and stop-check are tested in DS-my-strategy
# (test-close-obligation-peer-session-and-rearm.sh, no-changes-close cases).
OBLIGATION_LOG="$TEST_ROOT/obligation-calls.log"
cat > "$REPO/scripts/close_obligation.py" <<'EOF'
#!/usr/bin/env python3
import os, sys
with open(os.environ["OBLIGATION_LOG"], "a", encoding="utf-8") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
EOF
cat > "$REPO/scripts/isolate-push.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${IWE_TEST_PUSH_FAIL:-0}" = 1 ]; then
  echo "injected push failure" >&2
  exit 1
fi
git -C "$1" push -q origin HEAD:"$2"
EOF
chmod +x "$REPO/scripts/process-runner.py" "$REPO/scripts/ledger-append.sh" "$REPO/scripts/isolate-push.sh"
git -C "$REPO" add .gitignore scripts inbox
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

MC="$TEST_ROOT/MC-sessions"
MC_ORIGIN="$TEST_ROOT/mc-origin.git"
git init --bare -q "$MC_ORIGIN"
git init -q -b main "$MC"
git -C "$MC" config user.email test@example.com
git -C "$MC" config user.name "Test"
git -C "$MC" remote add origin "$MC_ORIGIN"
printf 'sessions\n' > "$MC/README.md"
git -C "$MC" add README.md
git -C "$MC" commit -qm init
git -C "$MC" push -q origin HEAD:main

export IWE_ROOT="$TEST_ROOT"
export IWE_SESSIONS_ROOT="$MC"
export CLAUDE_CODE_SESSION_ID="eeeeeeee-1111-2222-3333-444444444444"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""
export LEDGER_LOG OBLIGATION_LOG
unset IWE_CLOSE_ROUTE_ENFORCE

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }

# Opens an isolated session; sets SEM and WT. <slug> [close path]
open_session() {
  local extra=()
  [ -n "${2:-}" ] && extra=(--close-path "$2")
  (cd "$REPO" && bash "$GUARD" open --wp WP-561 --task fixture --slug "$1" --agent fixture --isolate "${extra[@]}") \
    >"$TEST_ROOT/open-$1.out" 2>&1 || { cat "$TEST_ROOT/open-$1.out" >&2; fail "open --isolate must succeed"; }
  SEM=$(grep -l "^slug: $1\$" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
  WT=$(sed -n 's/^isolated_worktree: //p' "$SEM")
  ORZ_REL=$(sed -n 's/^orz_file: //p' "$SEM")
  mkdir -p "$(dirname "$MC/$ORZ_REL")"
  printf -- '---\ndate: 2026-11-15\ntype: work\nwp: WP-561\nduration_h: 0.1\nartifacts: []\nagent: fixture\n---\n\n# Fixture\n\n## Главный инсайт\nf\n\n## Контекст\nf\n\n## Достигнуто\nf\n\n## Ключевые решения\nf\n' > "$MC/$ORZ_REL"
  git -C "$MC" add "$ORZ_REL"
  git -C "$MC" commit -qm "orz $1"
  git -C "$MC" push -q origin HEAD:main
}

journal() {  # <slug> <with peer reply: 1|0>
  local dir="$MC/2026-11/15/$1"
  mkdir -p "$dir"
  printf -- '---\nturn: 0\n---\nтема\n' > "$dir/00-writer.md"
  [ "$2" = 1 ] && printf -- '---\nturn: 1\n---\nреплика\n' > "$dir/01-peer-kimi.md"
  return 0
}

commit_in_copy() {  # <relative path> -- one session commit in the isolated copy
  mkdir -p "$(dirname "$WT/$1")"
  printf 'change %s\n' "$RANDOM" >> "$WT/$1"
  git -C "$WT" add "$1"
  git -C "$WT" commit -qm "session change $1"
}

explain() {  # <slug> <out>
  (cd "$REPO" && bash "$GUARD" close --explain --wp WP-561 --slug "$1" --agent fixture) >"$2" 2>&1 || true
}

real_close() {  # <slug> <err file> [pilot close word]; never fails the test by itself
  local word_args=()
  [ -z "${3:-}" ] || word_args=(--pilot-close-word "$3")
  (cd "$REPO" && bash "$GUARD" close --wp WP-561 --slug "$1" --agent fixture "${word_args[@]+"${word_args[@]}"}") \
    >"$2.out" 2>"$2" || true
}

has() { grep -q -- "$2" "$1" || { echo "--- $1" >&2; cat "$1" >&2; fail "$3"; }; }
lacks() { if grep -q -- "$2" "$1"; then echo "--- $1" >&2; cat "$1" >&2; fail "$3"; fi; }

echo "1. объявленная пир-сессия с правкой кода"
open_session enf-a peer-session
journal enf-a 1
commit_in_copy scripts/new-tool.sh
explain enf-a "$TEST_ROOT/x-a-off.out"
has "$TEST_ROOT/x-a-off.out" "Исполнение по фактам выключено" "explain must say the switch is off"
has "$TEST_ROOT/x-a-off.out" "обычное закрытие через раннер" "explain must name what the facts would do"
ok "выключатель выключен: объяснение говорит, что было бы"
IWE_CLOSE_ROUTE_ENFORCE=1 real_close enf-a "$TEST_ROOT/c-a-on.err"
has "$TEST_ROOT/c-a-on.err" "исполнение по фактам включено (WP-561 Ф61 этап 2): runner" "switch on: execution must be runner"
has "$TEST_ROOT/c-a-on.err" "по фактам нужно обычное закрытие" "switch on: close must explain why the runner is needed"
has "$TEST_ROOT/c-a-on.err" "нет terminal RUN-quick-close-enf-a" "switch on: close must demand the runner card"
lacks "$TEST_ROOT/c-a-on.err" "раннер не требуется" "switch on: the declaration must not bypass the runner"
[ -e "$SEM" ] || fail "a refused close must keep the session open"
grep 'close_route_observed .*"slug": "enf-a"' "$LEDGER_LOG" | grep '"enforced": true' | grep -q '"executed": "runner"' \
  || { cat "$LEDGER_LOG" >&2; fail "the ledger record must carry the switch and the executed route"; }
ok "выключатель включён: объявление не освобождает от раннера"
# WP-561 (18.11): the short peer-session close needs the pilot's own closing word
# (the host recovery switch IWE_PEER_CLOSE_WORD_ENFORCE=0 must not leak into the test).
IWE_PEER_CLOSE_WORD_ENFORCE=1 real_close enf-a "$TEST_ROOT/c-a-noword.err"
has "$TEST_ROOT/c-a-noword.err" "закрывается только по слову пилота" "switch off: a peer-session close without the pilot's word must be refused"
[ -e "$SEM" ] || fail "a close refused for the missing pilot word must keep the session open"
real_close enf-a "$TEST_ROOT/c-a-off.err" "закрывай"
has "$TEST_ROOT/c-a-off.err" "раннер не требуется (WP-484 Ф118)" "switch off: the declared peer bypass must still work"
lacks "$TEST_ROOT/c-a-off.err" "исполнение по фактам включено" "switch off: close must not execute the facts"
ok "выключатель выключен: прежний обход по объявлению"

echo "2. пир-сессия, менялись только журнал и карточка — тоже обычное закрытие"
open_session enf-b peer-session
journal enf-b 1
commit_in_copy inbox/WP-561/WP-561.md
IWE_CLOSE_ROUTE_ENFORCE=1 explain enf-b "$TEST_ROOT/x-b.out"
has "$TEST_ROOT/x-b.out" "Исполнение по фактам включено: обычное закрытие через раннер" "a journal+card peer session must take the runner"
has "$TEST_ROOT/x-b.out" "публикация журнала и отчёта пир-сессии" "the peer step must stay"
IWE_CLOSE_ROUTE_ENFORCE=1 real_close enf-b "$TEST_ROOT/c-b.err"
has "$TEST_ROOT/c-b.err" "нет terminal RUN-quick-close-enf-b" "a journal+card peer session must demand the runner card"
lacks "$TEST_ROOT/c-b.err" "раннер не требуется" "no short peer close is left"
ok "короткого закрытия пир-сессии нет: архивация фаз и РП идёт через раннер"

echo "3. объявленная пир-сессия без журнала и без правок (класс 15.11)"
# Its own conversation: the obligation is cleared only when no other mark of the
# conversation is open, and enf-b above stays open (refused without a runner card).
SID_D="dddddddd-1111-2222-3333-444444444444"
CLAUDE_CODE_SESSION_ID="$SID_D" open_session enf-d peer-session
CLAUDE_CODE_SESSION_ID="$SID_D" IWE_CLOSE_ROUTE_ENFORCE=1 real_close enf-d "$TEST_ROOT/c-d.err"
has "$TEST_ROOT/c-d.err" "по фактам изменений нет — раннер не требуется" "a proven-empty copy must be released"
grep -q -- "cancel --session-id $SID_D --action no-changes-close" "$OBLIGATION_LOG" \
  || { cat "$OBLIGATION_LOG" >&2; fail "an empty release must clear the obligation with no-changes-close (else Stop stays blocked)"; }
ok "пустая сессия снимает отметку"

echo "4. выключатель через файл и отмена переменной"
open_session enf-e peer-session
journal enf-e 1
commit_in_copy scripts/other.sh
IWE_CLOSE_ROUTE_ENFORCE=yes explain enf-e "$TEST_ROOT/x-e-bad.out"
has "$TEST_ROOT/x-e-bad.out" "не понят" "an unknown switch value must be reported"
has "$TEST_ROOT/x-e-bad.out" "Исполнение по фактам выключено" "an unknown switch value must keep execution off"
mkdir -p "$TEST_ROOT/.iwe-runtime"
: > "$TEST_ROOT/.iwe-runtime/close-route-enforce"
real_close enf-e "$TEST_ROOT/c-e-file.err"
has "$TEST_ROOT/c-e-file.err" "исполнение по фактам включено" "the flag file must switch execution on"
IWE_CLOSE_ROUTE_ENFORCE=0 real_close enf-e "$TEST_ROOT/c-e-zero.err"
has "$TEST_ROOT/c-e-zero.err" "исполнение по фактам включено" "IWE_CLOSE_ROUTE_ENFORCE=0 must not turn the flag file off"
lacks "$TEST_ROOT/c-e-zero.err" "раннер не требуется" "the agent's own variable must not bring back the bypass"
rm -f "$TEST_ROOT/.iwe-runtime/close-route-enforce"
ok "файл включает, переменная его не выключает, непонятное значение — предупреждение"

echo "5. продолжение держит решение первой попытки"
FN="$TEST_ROOT/fn.sh"
for fn in _unique_record_field _close_path_clears_obligation _close_execution _record_obligation_clear_action; do
  awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" {a=1} a {print} a && $0 == "}" {exit}' "$GUARD" >> "$FN"
  grep -q "^${fn}() {" "$FN" || fail "fixture: ${fn} not found in session-guard.sh"
done
# shellcheck source=/dev/null
source "$FN"
record() {  # <file> <close_path> <terminal reference or empty>
  { printf -- '---\nclose_path: %s\n---\n' "$2"; [ -n "$3" ] && printf 'close_delivery_terminal_reference: %s\n' "$3"; } > "$1"
  return 0
}
R="$TEST_ROOT/rec"
record "$R" peer-session "route-release-empty:s"; [ "$(_close_execution "$R" published "")" = release ] || fail "resume must keep release"
record "$R" peer-session "/runs/RUN-quick-close-s.md"; [ "$(_close_execution "$R" prepared "")" = runner ] || fail "a card resume must not fall back to the declaration"
record "$R" peer-session "declared-peer-session:s"; [ "$(_close_execution "$R" prepared "")" = legacy ] || fail "a close started under the old rules must finish under them"
ok "продолжение: заморожено при первой попытке"
record "$R" peer-session ""; [ "$(_close_execution "$R" none "not json" 2>/dev/null)" = runner ] || fail "no usable choice must not keep the declared peer bypass"
record "$R" publish-only ""; [ "$(_close_execution "$R" none "" 2>/dev/null)" = legacy ] || fail "no usable choice keeps other declarations as before"
ok "без ответа классификатора объявленный обход раннера не применяется"
record "$R" unknown "route-release-empty:s"; [ "$(_record_obligation_clear_action "$R")" = no-changes-close ] || fail "an empty release must clear with no-changes-close"
record "$R" no-code-changes "declared-no-code-changes:s"; [ "$(_record_obligation_clear_action "$R")" = no-changes-close ] || fail "a proven declared no-code-changes close must clear with no-changes-close"
record "$R" unknown "/runs/RUN-quick-close-s.md"; if _record_obligation_clear_action "$R" >/dev/null; then fail "a runner close of an undeclared session must not clear the obligation"; fi
record "$R" peer-session "/runs/RUN-quick-close-s.md"; [ "$(_record_obligation_clear_action "$R")" = peer-session-close ] || fail "a declared peer close still clears with peer-session-close"
ok "снятие обязательства пир-сессии: по объявлению и по замороженному снятию пустой сессии"

echo "6. полный close со старой отметкой при включённом выключателе"
open_session enf-legacy peer-session
commit_in_copy scripts/legacy.sh
IWE_TEST_PUSH_FAIL=1 real_close enf-legacy "$TEST_ROOT/c-legacy-prepare.err" "закрывай"
[ -e "$SEM" ] || fail "the injected push failure must leave the session open"
grep -q '^close_delivery_prepare_digest: ' "$SEM" \
  || { cat "$SEM" >&2; fail "the first attempt must reach prepared before push"; }
grep -q '^close_delivery_terminal_reference: declared-peer-session:' "$SEM" \
  || { cat "$SEM" >&2; fail "the first attempt must freeze the legacy route"; }
LEGACY_ATTEMPT=$(sed -n 's/^close_attempt_id: //p' "$SEM")
LEGACY_PREPARE=$(sed -n 's/^close_delivery_prepare_digest: //p' "$SEM")
[ -n "$LEGACY_ATTEMPT" ] || fail "prepared state must have an attempt id"
unset IWE_TEST_PUSH_FAIL
IWE_CLOSE_ROUTE_ENFORCE=1 real_close enf-legacy "$TEST_ROOT/c-legacy.err" "закрывай"
[ ! -e "$SEM" ] || { cat "$TEST_ROOT/c-legacy.err" >&2; fail "a legacy prepared close must finish under its original rules"; }
has "$TEST_ROOT/c-legacy.err" "продолжаю exact staged transition (prepared)" "the second close must resume the prepared transition"
has "$TEST_ROOT/c-legacy.err" "исполнение по фактам включено (WP-561 Ф61 этап 2): legacy" "the full close must report the frozen legacy route"
grep -q "^close_attempt_id: $LEGACY_ATTEMPT$" "$SEM.closed" \
  || fail "resume must keep the prepared attempt id"
grep -q "^close_delivery_prepare_digest: $LEGACY_PREPARE$" "$SEM.closed" \
  || fail "resume must keep the prepared digest"
lacks "$TEST_ROOT/c-legacy.err" "нет terminal RUN-quick-close-enf-legacy" "the new switch must not demand a runner for an old close"
ok "сквозное закрытие: старая отметка сохраняет прежний путь при включённом выключателе"

echo "PASS=$PASS: session-guard close route execution (WP-561 Ф61 stage 2)"
